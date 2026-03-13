import Foundation
import simd

struct TerrainVertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
    var color: SIMD3<Float>
    var shade: Float
}

struct TerrainMesh {
    let opaqueVertices: [TerrainVertex]
    let waterVertices: [TerrainVertex]
}

struct ChunkMeshSnapshot: Sendable {
    let coord: ChunkCoord
    let blocks: [UInt8]

    func blockAt(x: Int, y: Int, z: Int) -> BlockID {
        guard Chunk.isValid(x: x, y: y, z: z) else { return .air }
        let index = x + z * Chunk.sizeX + y * Chunk.sizeX * Chunk.sizeZ
        return BlockID(rawValue: blocks[index]) ?? .air
    }
}

struct WorldMeshSnapshot: Sendable {
    let chunks: [ChunkCoord: ChunkMeshSnapshot]
    let renderOrder: [ChunkCoord]

    func blockAt(worldX: Int, y: Int, worldZ: Int) -> BlockID {
        guard y >= 0 && y < Chunk.sizeY else { return .air }
        let coord = ChunkCoord(
            x: meshFloorDiv(worldX, Chunk.sizeX),
            z: meshFloorDiv(worldZ, Chunk.sizeZ)
        )
        guard let chunk = chunks[coord] else { return .air }
        let localX = meshPositiveMod(worldX, Chunk.sizeX)
        let localZ = meshPositiveMod(worldZ, Chunk.sizeZ)
        return chunk.blockAt(x: localX, y: y, z: localZ)
    }
}

enum TerrainMesher {
    static func buildMesh(from snapshot: WorldMeshSnapshot) -> TerrainMesh {
        var opaqueVertices: [TerrainVertex] = []
        var waterVertices: [TerrainVertex] = []
        opaqueVertices.reserveCapacity(snapshot.renderOrder.count * 4096)
        waterVertices.reserveCapacity(snapshot.renderOrder.count * 1024)

        for coord in snapshot.renderOrder {
            guard let chunk = snapshot.chunks[coord] else { continue }
            let baseX = chunk.coord.x * Chunk.sizeX
            let baseZ = chunk.coord.z * Chunk.sizeZ

            for y in 0..<Chunk.sizeY {
                for z in 0..<Chunk.sizeZ {
                    for x in 0..<Chunk.sizeX {
                        let block = chunk.blockAt(x: x, y: y, z: z)
                        guard block != .air else { continue }

                        let worldPos = SIMD3<Int>(baseX + x, y, baseZ + z)
                        for face in BlockFace.allCases {
                            let neighbor = worldPos &+ face.normal
                            let neighborBlock = snapshot.blockAt(worldX: neighbor.x, y: neighbor.y, worldZ: neighbor.z)
                            if block == .water {
                                guard neighborBlock != .water else { continue }
                                appendFace(
                                    face,
                                    at: worldPos,
                                    block: block,
                                    textures: textures(for: block),
                                    into: &waterVertices
                                )
                            } else {
                                guard neighborBlock == .air || neighborBlock == .water else { continue }
                                appendFace(
                                    face,
                                    at: worldPos,
                                    block: block,
                                    textures: textures(for: block),
                                    into: &opaqueVertices
                                )
                            }
                        }
                    }
                }
            }
        }

        return TerrainMesh(opaqueVertices: opaqueVertices, waterVertices: waterVertices)
    }

    private static func appendFace(
        _ face: BlockFace,
        at block: SIMD3<Int>,
        block blockType: BlockID,
        textures: BlockTextures,
        into vertices: inout [TerrainVertex]
    ) {
        let tile: AtlasTile
        switch face {
        case .top:
            tile = textures.top
        case .bottom:
            tile = textures.bottom
        case .north, .south, .east, .west:
            tile = textures.side
        }

        let atlasScale: Float = 1.0 / 16.0
        let uvMin = SIMD2<Float>(Float(tile.x) * atlasScale, Float(tile.y) * atlasScale)
        let uvMax = uvMin + SIMD2<Float>(repeating: atlasScale)
        let inset: Float = 0.0005

        let u0 = uvMin.x + inset
        let v0 = uvMin.y + inset
        let u1 = uvMax.x - inset
        let v1 = uvMax.y - inset

        let x = Float(block.x)
        let y = Float(block.y)
        let z = Float(block.z)

        let p000 = SIMD3<Float>(x, y, z)
        let p001 = SIMD3<Float>(x, y, z + 1)
        let p010 = SIMD3<Float>(x, y + 1, z)
        let p011 = SIMD3<Float>(x, y + 1, z + 1)
        let p100 = SIMD3<Float>(x + 1, y, z)
        let p101 = SIMD3<Float>(x + 1, y, z + 1)
        let p110 = SIMD3<Float>(x + 1, y + 1, z)
        let p111 = SIMD3<Float>(x + 1, y + 1, z + 1)

        let quad: [SIMD3<Float>]
        switch face {
        case .north:
            quad = [p000, p100, p110, p010]
        case .south:
            quad = [p101, p001, p011, p111]
        case .east:
            quad = [p100, p101, p111, p110]
        case .west:
            quad = [p001, p000, p010, p011]
        case .top:
            quad = [p010, p110, p111, p011]
        case .bottom:
            quad = [p001, p101, p100, p000]
        }

        let uv = [
            SIMD2<Float>(u0, v1),
            SIMD2<Float>(u1, v1),
            SIMD2<Float>(u1, v0),
            SIMD2<Float>(u0, v0)
        ]

        let color = tintColor(for: blockType, face: face)

        let shade = face.shade
        vertices.append(TerrainVertex(position: quad[0], uv: uv[0], color: color, shade: shade))
        vertices.append(TerrainVertex(position: quad[1], uv: uv[1], color: color, shade: shade))
        vertices.append(TerrainVertex(position: quad[2], uv: uv[2], color: color, shade: shade))
        vertices.append(TerrainVertex(position: quad[0], uv: uv[0], color: color, shade: shade))
        vertices.append(TerrainVertex(position: quad[2], uv: uv[2], color: color, shade: shade))
        vertices.append(TerrainVertex(position: quad[3], uv: uv[3], color: color, shade: shade))
    }

    private static func textures(for block: BlockID) -> BlockTextures {
        switch block {
        case .air:
            return BlockTextures(top: AtlasTile(x: 0, y: 0), bottom: AtlasTile(x: 0, y: 0), side: AtlasTile(x: 0, y: 0))
        case .grass:
            return BlockTextures(
                top: AtlasTile(x: 0, y: 0),
                bottom: AtlasTile(x: 2, y: 0),
                side: AtlasTile(x: 3, y: 0)
            )
        case .dirt:
            return BlockTextures(
                top: AtlasTile(x: 2, y: 0),
                bottom: AtlasTile(x: 2, y: 0),
                side: AtlasTile(x: 2, y: 0)
            )
        case .stone:
            return BlockTextures(
                top: AtlasTile(x: 1, y: 0),
                bottom: AtlasTile(x: 1, y: 0),
                side: AtlasTile(x: 1, y: 0)
            )
        case .sand:
            return BlockTextures(
                top: AtlasTile(x: 2, y: 1),
                bottom: AtlasTile(x: 2, y: 1),
                side: AtlasTile(x: 2, y: 1)
            )
        case .water:
            return BlockTextures(
                top: AtlasTile(x: 13, y: 12),
                bottom: AtlasTile(x: 13, y: 12),
                side: AtlasTile(x: 13, y: 12)
            )
        case .wood:
            return BlockTextures(
                top: AtlasTile(x: 5, y: 1),
                bottom: AtlasTile(x: 5, y: 1),
                side: AtlasTile(x: 4, y: 1)
            )
        case .leaves:
            return BlockTextures(
                top: AtlasTile(x: 4, y: 3),
                bottom: AtlasTile(x: 4, y: 3),
                side: AtlasTile(x: 4, y: 3)
            )
        }
    }

    private static func tintColor(for block: BlockID, face: BlockFace) -> SIMD3<Float> {
        switch block {
        case .grass where face == .top:
            return SIMD3<Float>(0.56, 0.86, 0.36)
        case .leaves:
            return SIMD3<Float>(0.56, 0.86, 0.36)
        default:
            return SIMD3<Float>(repeating: 1.0)
        }
    }
}

private func meshFloorDiv(_ lhs: Int, _ rhs: Int) -> Int {
    let quotient = lhs / rhs
    let remainder = lhs % rhs
    return remainder < 0 ? quotient - 1 : quotient
}

private func meshPositiveMod(_ lhs: Int, _ rhs: Int) -> Int {
    let value = lhs % rhs
    return value >= 0 ? value : value + rhs
}
