import MetalKit
import simd

struct FrameUniforms {
    var viewProjectionMatrix: float4x4
    var cameraPosition: float3
    var underwater: Float
}

@MainActor
final class Metal4ViewCoordinator: NSObject, MTKViewDelegate {
    struct ChunkMeshBuffer {
        let opaqueBuffer: MTLBuffer?
        let opaqueVertexCount: Int
        let waterBuffer: MTLBuffer?
        let waterVertexCount: Int
    }

    let device: MTLDevice
    let inputHandler = InputHandler()

    private let commandQueue: MTLCommandQueue
    private let opaquePipelineState: MTLRenderPipelineState
    private let waterPipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let translucentDepthState: MTLDepthStencilState
    private let texture: MTLTexture
    private let samplerState: MTLSamplerState
    private let world: VoxelWorld
    private let player: PlayerController

    private var chunkMeshBuffers: [ChunkCoord: ChunkMeshBuffer] = [:]
    private var chunkMeshTasks: [ChunkCoord: Task<Void, Never>] = [:]
    private var chunkMeshRevisions: [ChunkCoord: Int] = [:]
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            fatalError("Unable to create Metal device state.")
        }

        self.device = device
        self.commandQueue = commandQueue

        let world = VoxelWorld()
        self.world = world
        let player = PlayerController()
        let spawnY = Float(world.surfaceHeight(worldX: 0, worldZ: 0)) + 1.05
        player.position = float3(0.5, spawnY, 0.5)
        self.player = player

        do {
            let pipelines = try Metal4ViewCoordinator.buildPipelines(device: device)
            self.opaquePipelineState = pipelines.opaque
            self.waterPipelineState = pipelines.water
        } catch {
            fatalError("Unable to build render pipeline: \(error)")
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.isDepthWriteEnabled = true
        depthDescriptor.depthCompareFunction = .less
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            fatalError("Unable to create depth stencil state.")
        }
        self.depthState = depthState

        let translucentDepthDescriptor = MTLDepthStencilDescriptor()
        translucentDepthDescriptor.isDepthWriteEnabled = false
        translucentDepthDescriptor.depthCompareFunction = .lessEqual
        guard let translucentDepthState = device.makeDepthStencilState(descriptor: translucentDepthDescriptor) else {
            fatalError("Unable to create translucent depth state.")
        }
        self.translucentDepthState = translucentDepthState

        guard let samplerState = Metal4ViewCoordinator.buildSampler(device: device) else {
            fatalError("Unable to create sampler state.")
        }
        self.samplerState = samplerState

        do {
            self.texture = try TextureLoader.loadTerrainAtlas(device: device)
        } catch {
            fatalError("Unable to load terrain atlas: \(error)")
        }

        super.init()
        scheduleDirtyChunkMeshBuilds(for: world.consumeDirtyRenderableChunks())
    }

    func attach(to view: GameView) {
        view.device = device
        view.depthStencilPixelFormat = .depth32Float
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        guard let descriptor = view.currentRenderPassDescriptor else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTime()
        let deltaTime = max(1.0 / 240.0, min(Float(now - lastFrameTime), 1.0 / 20.0))
        lastFrameTime = now

        player.update(deltaTime: deltaTime, input: inputHandler, world: world)
        if world.updateStreaming(aroundWorldX: player.position.x, worldZ: player.position.z) {
            pruneChunkMeshes()
        }
        scheduleDirtyChunkMeshBuilds(for: world.consumeDirtyRenderableChunks())

        let underwater = world.isWater(
            worldX: Int(floor(player.eyePosition.x)),
            y: Int(floor(player.eyePosition.y)),
            worldZ: Int(floor(player.eyePosition.z))
        )

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = underwater
            ? MTLClearColor(red: 0.04, green: 0.20, blue: 0.28, alpha: 1)
            : MTLClearColor(red: 0.52, green: 0.80, blue: 0.94, alpha: 1)
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .dontCare
        descriptor.depthAttachment.clearDepth = 1

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let aspect = max(Float(view.drawableSize.width / max(view.drawableSize.height, 1)), 0.01)
        let projection = float4x4(perspectiveFov: radians(70), aspect: aspect, nearZ: 0.1, farZ: 500)
        let viewMatrix = float4x4(lookFrom: player.eyePosition, forward: player.forward, up: float3(0, 1, 0))
        var uniforms = FrameUniforms(
            viewProjectionMatrix: projection * viewMatrix,
            cameraPosition: player.eyePosition,
            underwater: underwater ? 1.0 : 0.0
        )

        encoder.setRenderPipelineState(opaquePipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(MTLCullMode.back)
        encoder.setFrontFacing(.clockwise)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        for coord in sortedRenderableChunkCoords() {
            guard let mesh = chunkMeshBuffers[coord] else { continue }
            if let opaqueBuffer = mesh.opaqueBuffer, mesh.opaqueVertexCount > 0 {
                encoder.setVertexBuffer(opaqueBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.opaqueVertexCount)
            }
        }
        encoder.setRenderPipelineState(waterPipelineState)
        encoder.setDepthStencilState(translucentDepthState)
        for coord in sortedRenderableChunkCoords() {
            guard let mesh = chunkMeshBuffers[coord] else { continue }
            if let waterBuffer = mesh.waterBuffer, mesh.waterVertexCount > 0 {
                encoder.setVertexBuffer(waterBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.waterVertexCount)
            }
        }
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func buildPipelines(device: MTLDevice) throws -> (opaque: MTLRenderPipelineState, water: MTLRenderPipelineState) {
        let shaderURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal")!
        let source = try String(contentsOf: shaderURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)

        let opaqueDescriptor = MTLRenderPipelineDescriptor()
        opaqueDescriptor.vertexFunction = library.makeFunction(name: "terrainVertex")
        opaqueDescriptor.fragmentFunction = library.makeFunction(name: "terrainFragment")
        opaqueDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        opaqueDescriptor.depthAttachmentPixelFormat = .depth32Float
        opaqueDescriptor.vertexDescriptor = buildVertexDescriptor()

        let waterDescriptor = MTLRenderPipelineDescriptor()
        waterDescriptor.vertexFunction = library.makeFunction(name: "terrainVertex")
        waterDescriptor.fragmentFunction = library.makeFunction(name: "waterFragment")
        waterDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        waterDescriptor.depthAttachmentPixelFormat = .depth32Float
        waterDescriptor.vertexDescriptor = buildVertexDescriptor()
        waterDescriptor.colorAttachments[0].isBlendingEnabled = true
        waterDescriptor.colorAttachments[0].rgbBlendOperation = .add
        waterDescriptor.colorAttachments[0].alphaBlendOperation = .add
        waterDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        waterDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        waterDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        waterDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return (
            opaque: try device.makeRenderPipelineState(descriptor: opaqueDescriptor),
            water: try device.makeRenderPipelineState(descriptor: waterDescriptor)
        )
    }

    private static func buildVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        let positionOffset = 0
        let uvOffset = MemoryLayout<SIMD3<Float>>.stride
        let colorOffset = alignedOffset(
            uvOffset + MemoryLayout<SIMD2<Float>>.stride,
            to: MemoryLayout<SIMD3<Float>>.alignment
        )
        let shadeOffset = colorOffset + MemoryLayout<SIMD3<Float>>.stride

        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[0].offset = positionOffset

        descriptor.attributes[1].format = .float2
        descriptor.attributes[1].bufferIndex = 0
        descriptor.attributes[1].offset = uvOffset

        descriptor.attributes[2].format = .float3
        descriptor.attributes[2].bufferIndex = 0
        descriptor.attributes[2].offset = colorOffset

        descriptor.attributes[3].format = .float
        descriptor.attributes[3].bufferIndex = 0
        descriptor.attributes[3].offset = shadeOffset

        descriptor.layouts[0].stride = MemoryLayout<TerrainVertex>.stride
        descriptor.layouts[0].stepFunction = .perVertex
        return descriptor
    }

    private static func buildSampler(device: MTLDevice) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .nearest
        descriptor.magFilter = .nearest
        descriptor.mipFilter = .nearest
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        return device.makeSamplerState(descriptor: descriptor)
    }

    private func scheduleDirtyChunkMeshBuilds(for dirtyCoords: Set<ChunkCoord>) {
        for coord in dirtyCoords {
            scheduleChunkMeshBuild(for: coord)
        }
    }

    private func scheduleChunkMeshBuild(for coord: ChunkCoord) {
        guard let snapshot = world.makeChunkSnapshot(coord: coord) else {
            chunkMeshTasks[coord]?.cancel()
            chunkMeshTasks.removeValue(forKey: coord)
            chunkMeshRevisions.removeValue(forKey: coord)
            chunkMeshBuffers.removeValue(forKey: coord)
            return
        }

        chunkMeshTasks[coord]?.cancel()
        let revision = (chunkMeshRevisions[coord] ?? 0) + 1
        chunkMeshRevisions[coord] = revision

        chunkMeshTasks[coord] = Task.detached(priority: .utility) { [weak self] in
            let mesh = TerrainMesher.buildMesh(from: snapshot)
            await MainActor.run {
                self?.applyChunkMesh(mesh, coord: coord, revision: revision)
            }
        }
    }

    private func applyChunkMesh(_ mesh: TerrainMesh, coord: ChunkCoord, revision: Int) {
        guard revision == chunkMeshRevisions[coord] else { return }
        defer { chunkMeshTasks.removeValue(forKey: coord) }

        guard world.currentRenderableChunkCoords().contains(coord) else {
            chunkMeshBuffers.removeValue(forKey: coord)
            return
        }

        guard mesh.opaqueVertices.isEmpty == false || mesh.waterVertices.isEmpty == false else {
            chunkMeshBuffers.removeValue(forKey: coord)
            return
        }

        let opaqueBuffer: MTLBuffer?
        if mesh.opaqueVertices.isEmpty {
            opaqueBuffer = nil
        } else {
            opaqueBuffer = device.makeBuffer(
                bytes: mesh.opaqueVertices,
                length: MemoryLayout<TerrainVertex>.stride * mesh.opaqueVertices.count
            )
        }

        let waterBuffer: MTLBuffer?
        if mesh.waterVertices.isEmpty {
            waterBuffer = nil
        } else {
            waterBuffer = device.makeBuffer(
                bytes: mesh.waterVertices,
                length: MemoryLayout<TerrainVertex>.stride * mesh.waterVertices.count
            )
        }

        chunkMeshBuffers[coord] = ChunkMeshBuffer(
            opaqueBuffer: opaqueBuffer,
            opaqueVertexCount: mesh.opaqueVertices.count,
            waterBuffer: waterBuffer,
            waterVertexCount: mesh.waterVertices.count
        )
    }

    private func pruneChunkMeshes() {
        let renderable = world.currentRenderableChunkCoords()
        for coord in chunkMeshBuffers.keys where !renderable.contains(coord) {
            chunkMeshBuffers.removeValue(forKey: coord)
        }
        for coord in chunkMeshTasks.keys where !renderable.contains(coord) {
            chunkMeshTasks[coord]?.cancel()
            chunkMeshTasks.removeValue(forKey: coord)
            chunkMeshRevisions.removeValue(forKey: coord)
        }
    }

    private func sortedRenderableChunkCoords() -> [ChunkCoord] {
        world.currentRenderableChunkCoords().sorted {
            if $0.z == $1.z { return $0.x < $1.x }
            return $0.z < $1.z
        }
    }
}

private func alignedOffset(_ offset: Int, to alignment: Int) -> Int {
    let remainder = offset % alignment
    if remainder == 0 {
        return offset
    }
    return offset + (alignment - remainder)
}
