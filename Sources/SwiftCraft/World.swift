import Compression
import GameplayKit
import Foundation
import simd

enum BlockID: UInt8 {
    case air = 0
    case grass
    case dirt
    case stone
    case sand
    case water
    case wood
    case leaves
}

enum BlockFace: Int, CaseIterable {
    case north
    case south
    case east
    case west
    case top
    case bottom

    var normal: SIMD3<Int> {
        switch self {
        case .north: return SIMD3<Int>(0, 0, -1)
        case .south: return SIMD3<Int>(0, 0, 1)
        case .east: return SIMD3<Int>(1, 0, 0)
        case .west: return SIMD3<Int>(-1, 0, 0)
        case .top: return SIMD3<Int>(0, 1, 0)
        case .bottom: return SIMD3<Int>(0, -1, 0)
        }
    }

    var shade: Float {
        switch self {
        case .top: return 1.0
        case .bottom: return 0.55
        case .east, .west: return 0.75
        case .north, .south: return 0.85
        }
    }
}

struct AtlasTile {
    let x: Int
    let y: Int
}

struct BlockTextures {
    let top: AtlasTile
    let bottom: AtlasTile
    let side: AtlasTile
}

struct ChunkCoord: Hashable, Sendable {
    let x: Int
    let z: Int
}

final class Chunk: @unchecked Sendable {
    static let sizeX = 16
    static let sizeY = 64
    static let sizeZ = 16
    static let blockCount = sizeX * sizeY * sizeZ

    let coord: ChunkCoord
    private var blocks: [UInt8]

    init(coord: ChunkCoord, blocks: [UInt8]? = nil) {
        self.coord = coord
        self.blocks = blocks ?? [UInt8](repeating: BlockID.air.rawValue, count: Self.blockCount)
    }

    func setBlock(x: Int, y: Int, z: Int, _ block: BlockID) {
        guard Self.isValid(x: x, y: y, z: z) else { return }
        blocks[index(x: x, y: y, z: z)] = block.rawValue
    }

    func blockAt(x: Int, y: Int, z: Int) -> BlockID {
        guard Self.isValid(x: x, y: y, z: z) else { return .air }
        return BlockID(rawValue: blocks[index(x: x, y: y, z: z)]) ?? .air
    }

    func serializedBlocks() -> [UInt8] {
        blocks
    }

    private func index(x: Int, y: Int, z: Int) -> Int {
        x + z * Self.sizeX + y * Self.sizeX * Self.sizeZ
    }

    static func isValid(x: Int, y: Int, z: Int) -> Bool {
        (0..<sizeX).contains(x) && (0..<sizeY).contains(y) && (0..<sizeZ).contains(z)
    }
}

struct NoiseSettings: Sendable {
    let baseFrequency: Double
    let baseOctaves: Int32
    let basePersistence: Double
    let baseLacunarity: Double
    let baseSeed: Int32
    let detailFrequency: Double
    let detailOctaves: Int32
    let detailPersistence: Double
    let detailLacunarity: Double
    let detailSeed: Int32
    let caveFrequency: Double
    let caveOctaves: Int32
    let cavePersistence: Double
    let caveLacunarity: Double
    let caveSeed: Int32
}

struct CompressedChunkStorage: Sendable {
    let compressed: Data
    let uncompressedSize: Int

    init(chunk: Chunk) {
        let bytes = chunk.serializedBlocks()
        self.uncompressedSize = bytes.count
        self.compressed = CompressionCodec.compress(bytes)
    }

    func decompress(coord: ChunkCoord) -> Chunk {
        let rawBytes = CompressionCodec.decompress(compressed, outputSize: uncompressedSize)
        return Chunk(coord: coord, blocks: rawBytes)
    }
}

struct ChunkLoadResult: Sendable {
    let coord: ChunkCoord
    let chunk: Chunk
}

enum CompressionCodec {
    static func compress(_ input: [UInt8]) -> Data {
        if input.isEmpty { return Data() }
        let destinationCapacity = max(64, input.count * 2)
        var destination = [UInt8](repeating: 0, count: destinationCapacity)
        let compressedSize = input.withUnsafeBytes { sourcePtr in
            destination.withUnsafeMutableBytes { destPtr in
                compression_encode_buffer(
                    destPtr.bindMemory(to: UInt8.self).baseAddress!,
                    destinationCapacity,
                    sourcePtr.bindMemory(to: UInt8.self).baseAddress!,
                    input.count,
                    nil,
                    COMPRESSION_LZ4
                )
            }
        }

        if compressedSize == 0 {
            return Data(input)
        }
        return Data(destination.prefix(compressedSize))
    }

    static func decompress(_ input: Data, outputSize: Int) -> [UInt8] {
        if input.isEmpty { return [] }
        var output = [UInt8](repeating: 0, count: outputSize)
        let decodedSize = input.withUnsafeBytes { sourcePtr in
            output.withUnsafeMutableBytes { destPtr in
                compression_decode_buffer(
                    destPtr.bindMemory(to: UInt8.self).baseAddress!,
                    outputSize,
                    sourcePtr.bindMemory(to: UInt8.self).baseAddress!,
                    input.count,
                    nil,
                    COMPRESSION_LZ4
                )
            }
        }

        if decodedSize == outputSize {
            return output
        }

        // Fall back to treating the payload as raw bytes if LZ4 didn't decode.
        return Array(input.prefix(outputSize))
    }
}

@MainActor
final class VoxelWorld {
    let renderRadiusInChunks: Int
    let activeRadiusInChunks: Int

    private let noiseSettings: NoiseSettings

    private var activeChunks: [ChunkCoord: Chunk] = [:]
    private var compressedChunks: [ChunkCoord: CompressedChunkStorage] = [:]
    private var pendingCompressedChunks: [ChunkCoord: Chunk] = [:]
    private var pendingLoads: Set<ChunkCoord> = []
    private var pendingCompression: Set<ChunkCoord> = []
    private var streamedCenter: ChunkCoord?
    private var dirtyRenderableChunks: Set<ChunkCoord> = []

    init(renderRadiusInChunks: Int = 3, seed: Int32 = 1337) {
        self.renderRadiusInChunks = renderRadiusInChunks
        self.activeRadiusInChunks = renderRadiusInChunks + 1
        self.noiseSettings = NoiseSettings(
            baseFrequency: 0.015,
            baseOctaves: 6,
            basePersistence: 0.5,
            baseLacunarity: 2.1,
            baseSeed: seed,
            detailFrequency: 0.06,
            detailOctaves: 4,
            detailPersistence: 0.4,
            detailLacunarity: 2.0,
            detailSeed: seed &+ 17,
            caveFrequency: 0.045,
            caveOctaves: 3,
            cavePersistence: 0.55,
            caveLacunarity: 2.0,
            caveSeed: seed &+ 101
        )
        bootstrap(center: ChunkCoord(x: 0, z: 0))
    }

    func updateStreaming(aroundWorldX worldX: Float, worldZ: Float) -> Bool {
        let center = ChunkCoord(
            x: floorDiv(Int(floor(worldX)), Chunk.sizeX),
            z: floorDiv(Int(floor(worldZ)), Chunk.sizeZ)
        )

        let oldRenderable = currentRenderableChunkCoords()
        guard center != streamedCenter else { return false }
        streamedCenter = center

        var requiredActive: Set<ChunkCoord> = []
        for z in (center.z - activeRadiusInChunks)...(center.z + activeRadiusInChunks) {
            for x in (center.x - activeRadiusInChunks)...(center.x + activeRadiusInChunks) {
                requiredActive.insert(ChunkCoord(x: x, z: z))
            }
        }

        for coord in requiredActive where activeChunks[coord] == nil {
            if let chunk = pendingCompressedChunks.removeValue(forKey: coord) {
                activeChunks[coord] = chunk
                markChunkAndNeighborsDirty(coord)
            } else if compressedChunks[coord] != nil {
                scheduleChunkDecompression(coord: coord)
            } else {
                scheduleChunkLoad(coord: coord)
            }
        }

        for coord in activeChunks.keys.filter({ !requiredActive.contains($0) }) {
            if let chunk = activeChunks.removeValue(forKey: coord) {
                pendingCompressedChunks[coord] = chunk
                scheduleChunkCompression(coord: coord, chunk: chunk)
            }
        }

        let newRenderable = currentRenderableChunkCoords()
        let changedRenderable = oldRenderable.symmetricDifference(newRenderable)
        for coord in changedRenderable {
            markChunkAndNeighborsDirty(coord)
        }

        return true
    }

    func consumeDirtyRenderableChunks() -> Set<ChunkCoord> {
        let dirty = dirtyRenderableChunks
        dirtyRenderableChunks.removeAll()
        return dirty
    }

    func streamStats() -> (active: Int, compressed: Int) {
        (activeChunks.count, compressedChunks.count)
    }

    func makeRenderSnapshot() -> WorldMeshSnapshot {
        guard let center = streamedCenter else {
            return WorldMeshSnapshot(chunks: [:], renderOrder: [])
        }

        let renderable = activeChunks.values
            .filter { abs($0.coord.x - center.x) <= renderRadiusInChunks && abs($0.coord.z - center.z) <= renderRadiusInChunks }
            .sorted {
                if $0.coord.z == $1.coord.z { return $0.coord.x < $1.coord.x }
                return $0.coord.z < $1.coord.z
            }

        var chunks: [ChunkCoord: ChunkMeshSnapshot] = [:]
        var order: [ChunkCoord] = []
        chunks.reserveCapacity(renderable.count)
        order.reserveCapacity(renderable.count)

        for chunk in renderable {
            let snapshot = ChunkMeshSnapshot(coord: chunk.coord, blocks: chunk.serializedBlocks())
            chunks[chunk.coord] = snapshot
            order.append(chunk.coord)
        }

        return WorldMeshSnapshot(chunks: chunks, renderOrder: order)
    }

    func makeChunkSnapshot(coord: ChunkCoord) -> WorldMeshSnapshot? {
        guard currentRenderableChunkCoords().contains(coord), let centerChunk = activeChunks[coord] else {
            return nil
        }

        var chunks: [ChunkCoord: ChunkMeshSnapshot] = [:]
        for z in (coord.z - 1)...(coord.z + 1) {
            for x in (coord.x - 1)...(coord.x + 1) {
                let neighborCoord = ChunkCoord(x: x, z: z)
                if let chunk = activeChunks[neighborCoord] {
                    chunks[neighborCoord] = ChunkMeshSnapshot(coord: neighborCoord, blocks: chunk.serializedBlocks())
                }
            }
        }
        chunks[coord] = ChunkMeshSnapshot(coord: centerChunk.coord, blocks: centerChunk.serializedBlocks())
        return WorldMeshSnapshot(chunks: chunks, renderOrder: [coord])
    }

    func currentRenderableChunkCoords() -> Set<ChunkCoord> {
        guard let center = streamedCenter else { return [] }
        var coords: Set<ChunkCoord> = []
        for z in (center.z - renderRadiusInChunks)...(center.z + renderRadiusInChunks) {
            for x in (center.x - renderRadiusInChunks)...(center.x + renderRadiusInChunks) {
                coords.insert(ChunkCoord(x: x, z: z))
            }
        }
        return coords
    }

    func activeRenderableChunks() -> [Chunk] {
        guard let center = streamedCenter else { return [] }
        return activeChunks.values
            .filter { abs($0.coord.x - center.x) <= renderRadiusInChunks && abs($0.coord.z - center.z) <= renderRadiusInChunks }
            .sorted {
                if $0.coord.z == $1.coord.z { return $0.coord.x < $1.coord.x }
                return $0.coord.z < $1.coord.z
            }
    }

    func blockAt(worldX: Int, y: Int, worldZ: Int) -> BlockID {
        guard y >= 0 && y < Chunk.sizeY else { return .air }
        let coord = ChunkCoord(
            x: floorDiv(worldX, Chunk.sizeX),
            z: floorDiv(worldZ, Chunk.sizeZ)
        )
        let localX = positiveMod(worldX, Chunk.sizeX)
        let localZ = positiveMod(worldZ, Chunk.sizeZ)

        if let chunk = activeChunks[coord] {
            return chunk.blockAt(x: localX, y: y, z: localZ)
        }
        if let chunk = pendingCompressedChunks[coord] {
            return chunk.blockAt(x: localX, y: y, z: localZ)
        }
        if let storage = compressedChunks[coord] {
            return storage.decompress(coord: coord).blockAt(x: localX, y: y, z: localZ)
        }
        return .air
    }

    func isSolid(worldX: Int, y: Int, worldZ: Int) -> Bool {
        let block = blockAt(worldX: worldX, y: y, worldZ: worldZ)
        return block != .air && block != .water
    }

    func isWater(worldX: Int, y: Int, worldZ: Int) -> Bool {
        blockAt(worldX: worldX, y: y, worldZ: worldZ) == .water
    }

    func surfaceHeight(worldX: Int, worldZ: Int) -> Int {
        for y in stride(from: Chunk.sizeY - 1, through: 0, by: -1) {
            if isSolid(worldX: worldX, y: y, worldZ: worldZ) {
                return y
            }
        }
        return 0
    }

    private func generateChunk(coord: ChunkCoord) -> Chunk {
        let chunk = Chunk(coord: coord)
        let noises = Self.makeNoises(settings: noiseSettings)
        Self.generate(chunk: chunk, heightNoise: noises.height, detailNoise: noises.detail, caveNoise: noises.cave)
        return chunk
    }

    private func bootstrap(center: ChunkCoord) {
        streamedCenter = center
        for z in (center.z - activeRadiusInChunks)...(center.z + activeRadiusInChunks) {
            for x in (center.x - activeRadiusInChunks)...(center.x + activeRadiusInChunks) {
                let coord = ChunkCoord(x: x, z: z)
                activeChunks[coord] = generateChunk(coord: coord)
            }
        }
        dirtyRenderableChunks = currentRenderableChunkCoords()
    }

    private func scheduleChunkLoad(coord: ChunkCoord) {
        guard !pendingLoads.contains(coord) else { return }
        pendingLoads.insert(coord)
        let settings = noiseSettings

        Task.detached(priority: .utility) {
            let chunk = VoxelWorld.generateChunk(coord: coord, noiseSettings: settings)
            await MainActor.run { [weak self] in
                self?.completeChunkLoad(ChunkLoadResult(coord: coord, chunk: chunk))
            }
        }
    }

    private func scheduleChunkDecompression(coord: ChunkCoord) {
        guard !pendingLoads.contains(coord), let storage = compressedChunks[coord] else { return }
        pendingLoads.insert(coord)
        Task.detached(priority: .utility) {
            let chunk = storage.decompress(coord: coord)
            await MainActor.run { [weak self] in
                self?.completeChunkLoad(ChunkLoadResult(coord: coord, chunk: chunk))
            }
        }
    }

    private func completeChunkLoad(_ result: ChunkLoadResult) {
        let coord = result.coord
        pendingLoads.remove(coord)
        guard activeChunks[coord] == nil else { return }
        guard let center = streamedCenter else { return }
        let withinActiveRadius = abs(coord.x - center.x) <= activeRadiusInChunks && abs(coord.z - center.z) <= activeRadiusInChunks
        guard withinActiveRadius else { return }

        activeChunks[coord] = result.chunk
        pendingCompressedChunks.removeValue(forKey: coord)
        compressedChunks.removeValue(forKey: coord)
        markChunkAndNeighborsDirty(coord)
    }

    private func scheduleChunkCompression(coord: ChunkCoord, chunk: Chunk) {
        guard !pendingCompression.contains(coord) else { return }
        pendingCompression.insert(coord)
        Task.detached(priority: .utility) {
            let storage = CompressedChunkStorage(chunk: chunk)
            await MainActor.run { [weak self] in
                self?.completeChunkCompression(coord: coord, storage: storage)
            }
        }
    }

    private func completeChunkCompression(coord: ChunkCoord, storage: CompressedChunkStorage) {
        pendingCompression.remove(coord)
        guard pendingCompressedChunks[coord] != nil else { return }
        pendingCompressedChunks.removeValue(forKey: coord)
        compressedChunks[coord] = storage
    }

    private func markChunkAndNeighborsDirty(_ coord: ChunkCoord) {
        let renderable = currentRenderableChunkCoords()
        for z in (coord.z - 1)...(coord.z + 1) {
            for x in (coord.x - 1)...(coord.x + 1) {
                let candidate = ChunkCoord(x: x, z: z)
                if renderable.contains(candidate) {
                    dirtyRenderableChunks.insert(candidate)
                }
            }
        }
    }

    nonisolated private static func generateChunk(coord: ChunkCoord, noiseSettings: NoiseSettings) -> Chunk {
        let chunk = Chunk(coord: coord)
        let noises = makeNoises(settings: noiseSettings)
        generate(chunk: chunk, heightNoise: noises.height, detailNoise: noises.detail, caveNoise: noises.cave)
        return chunk
    }

    nonisolated private static func makeNoises(settings: NoiseSettings) -> (height: GKNoise, detail: GKNoise, cave: GKNoise) {
        let baseSource = GKPerlinNoiseSource(
            frequency: settings.baseFrequency,
            octaveCount: Int(settings.baseOctaves),
            persistence: settings.basePersistence,
            lacunarity: settings.baseLacunarity,
            seed: settings.baseSeed
        )
        let detailSource = GKPerlinNoiseSource(
            frequency: settings.detailFrequency,
            octaveCount: Int(settings.detailOctaves),
            persistence: settings.detailPersistence,
            lacunarity: settings.detailLacunarity,
            seed: settings.detailSeed
        )
        let caveSource = GKPerlinNoiseSource(
            frequency: settings.caveFrequency,
            octaveCount: Int(settings.caveOctaves),
            persistence: settings.cavePersistence,
            lacunarity: settings.caveLacunarity,
            seed: settings.caveSeed
        )
        return (GKNoise(baseSource), GKNoise(detailSource), GKNoise(caveSource))
    }

    nonisolated private static func generate(chunk: Chunk, heightNoise: GKNoise, detailNoise: GKNoise, caveNoise: GKNoise) {
        let baseX = chunk.coord.x * Chunk.sizeX
        let baseZ = chunk.coord.z * Chunk.sizeZ
        var heightMap = [Int](repeating: 0, count: Chunk.sizeX * Chunk.sizeZ)

        for z in 0..<Chunk.sizeZ {
            for x in 0..<Chunk.sizeX {
                let worldX = baseX + x
                let worldZ = baseZ + z
                let height = terrainHeight(worldX: worldX, worldZ: worldZ, heightNoise: heightNoise, detailNoise: detailNoise)
                heightMap[x + z * Chunk.sizeX] = height

                for y in 0...height {
                    chunk.setBlock(x: x, y: y, z: z, .stone)
                }
            }
        }

        carveCaves(in: chunk, caveNoise: caveNoise, heightMap: heightMap)
        applySurfaceMaterialsAndWater(in: chunk)
        placeTrees(in: chunk)
    }

    nonisolated private static func terrainHeight(worldX: Int, worldZ: Int, heightNoise: GKNoise, detailNoise: GKNoise) -> Int {
        let position = vector_float2(Float(worldX), Float(worldZ))
        let base = heightNoise.value(atPosition: position)
        let detail = detailNoise.value(atPosition: position)
        let combined = Float(base) * 14 + Float(detail) * 4
        let plateau = sin(Float(worldX) * 0.05) * cos(Float(worldZ) * 0.05) * 2.5
        let height = Int((combined + plateau + 24).rounded(.toNearestOrAwayFromZero))
        return max(4, min(Chunk.sizeY - 2, height))
    }

    nonisolated private static func carveCaves(in chunk: Chunk, caveNoise: GKNoise, heightMap: [Int]) {
        let baseX = chunk.coord.x * Chunk.sizeX
        let baseZ = chunk.coord.z * Chunk.sizeZ

        for z in 0..<Chunk.sizeZ {
            for x in 0..<Chunk.sizeX {
                let columnHeight = heightMap[x + z * Chunk.sizeX]
                guard columnHeight > 12 else { continue }

                for y in 5..<(columnHeight - 3) {
                    let caveSample = vector_float2(
                        Float(baseX + x) + Float(y) * 0.85,
                        Float(baseZ + z) - Float(y) * 1.15
                    )
                    let density = caveNoise.value(atPosition: caveSample)
                    let verticalBias = abs(Float(y) - Float(columnHeight) * 0.45) / Float(max(columnHeight, 1))
                    if density > 0.58 - verticalBias * 0.12 {
                        chunk.setBlock(x: x, y: y, z: z, .air)
                    }
                }
            }
        }
    }

    nonisolated private static func applySurfaceMaterialsAndWater(in chunk: Chunk) {
        let seaLevel = 18

        for z in 0..<Chunk.sizeZ {
            for x in 0..<Chunk.sizeX {
                let topSolid = highestSolidY(in: chunk, x: x, z: z)

                if let topSolid {
                    let isBeach = topSolid <= seaLevel + 1
                    let surface = isBeach ? BlockID.sand : BlockID.grass
                    let subsurface = isBeach ? BlockID.sand : BlockID.dirt

                    chunk.setBlock(x: x, y: topSolid, z: z, surface)
                    for y in max(0, topSolid - 3)..<topSolid {
                        if chunk.blockAt(x: x, y: y, z: z) != .air {
                            chunk.setBlock(x: x, y: y, z: z, subsurface)
                        }
                    }
                }

                let fillStart = min((topSolid ?? -1) + 1, seaLevel)
                if fillStart <= seaLevel {
                    for y in max(fillStart, 0)...seaLevel where chunk.blockAt(x: x, y: y, z: z) == .air {
                        chunk.setBlock(x: x, y: y, z: z, .water)
                    }
                }
            }
        }
    }

    nonisolated private static func placeTrees(in chunk: Chunk) {
        let baseX = chunk.coord.x * Chunk.sizeX
        let baseZ = chunk.coord.z * Chunk.sizeZ

        for z in 2..<(Chunk.sizeZ - 2) {
            for x in 2..<(Chunk.sizeX - 2) {
                guard let height = highestSolidY(in: chunk, x: x, z: z) else { continue }
                guard height >= 8 && height < Chunk.sizeY - 8 else { continue }
                guard chunk.blockAt(x: x, y: height, z: z) == .grass else { continue }
                guard treeChance(worldX: baseX + x, worldZ: baseZ + z) else { continue }

                let trunkHeight = 4 + deterministicValue(worldX: baseX + x, worldZ: baseZ + z, salt: 91) % 3
                let canopyBase = height + trunkHeight - 2
                guard canopyBase + 2 < Chunk.sizeY else { continue }

                var clear = true
                for leafY in (height + 1)...(canopyBase + 2) {
                    let radius = leafY >= canopyBase + 1 ? 1 : 2
                    for leafZ in (z - radius)...(z + radius) {
                        for leafX in (x - radius)...(x + radius) {
                            if chunk.blockAt(x: leafX, y: leafY, z: leafZ) != .air {
                                clear = false
                            }
                        }
                    }
                }
                guard clear else { continue }

                for trunkY in (height + 1)...(height + trunkHeight) {
                    chunk.setBlock(x: x, y: trunkY, z: z, .wood)
                }

                for leafY in canopyBase...(canopyBase + 2) {
                    let radius = leafY >= canopyBase + 1 ? 1 : 2
                    for leafZ in (z - radius)...(z + radius) {
                        for leafX in (x - radius)...(x + radius) {
                            let dx = abs(leafX - x)
                            let dz = abs(leafZ - z)
                            if dx == radius && dz == radius && leafY == canopyBase {
                                continue
                            }
                            if chunk.blockAt(x: leafX, y: leafY, z: leafZ) == .air {
                                chunk.setBlock(x: leafX, y: leafY, z: leafZ, .leaves)
                            }
                        }
                    }
                }
                chunk.setBlock(x: x, y: canopyBase + 2, z: z, .leaves)
            }
        }
    }

    nonisolated private static func highestSolidY(in chunk: Chunk, x: Int, z: Int) -> Int? {
        for y in stride(from: Chunk.sizeY - 1, through: 0, by: -1) {
            let block = chunk.blockAt(x: x, y: y, z: z)
            if block != .air && block != .water && block != .leaves {
                return y
            }
        }
        return nil
    }

    nonisolated private static func treeChance(worldX: Int, worldZ: Int) -> Bool {
        deterministicValue(worldX: worldX, worldZ: worldZ, salt: 17) % 100 < 4
    }

    nonisolated private static func deterministicValue(worldX: Int, worldZ: Int, salt: Int) -> Int {
        var value = UInt64(bitPattern: Int64(worldX &* 73428767 ^ worldZ &* 912931 ^ salt &* 19349663))
        value ^= value >> 33
        value &*= 0xff51afd7ed558ccd
        value ^= value >> 33
        return Int(value & 0x7fffffff)
    }
}

private func floorDiv(_ lhs: Int, _ rhs: Int) -> Int {
    let quotient = lhs / rhs
    let remainder = lhs % rhs
    return remainder < 0 ? quotient - 1 : quotient
}

private func positiveMod(_ lhs: Int, _ rhs: Int) -> Int {
    let value = lhs % rhs
    return value >= 0 ? value : value + rhs
}
