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
                                    snapshot: snapshot,
                                    into: &waterVertices
                                )
                            } else {
                                guard neighborBlock == .air || neighborBlock == .water else { continue }
                                appendFace(
                                    face,
                                    at: worldPos,
                                    block: block,
                                    textures: textures(for: block),
                                    snapshot: snapshot,
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
        snapshot: WorldMeshSnapshot,
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

        let faceCenter = block &+ face.normal
        let skyLight: Float = hasSkyAccess(worldX: faceCenter.x, y: faceCenter.y, worldZ: faceCenter.z, in: snapshot) ? 1.0 : 0.15

        // Water gets uniform shading — no AO to keep the surface visually flat.
        if blockType == .water {
            let s = face.shade * skyLight
            vertices.append(contentsOf: [
                TerrainVertex(position: quad[0], uv: uv[0], color: color, shade: s),
                TerrainVertex(position: quad[1], uv: uv[1], color: color, shade: s),
                TerrainVertex(position: quad[2], uv: uv[2], color: color, shade: s),
                TerrainVertex(position: quad[0], uv: uv[0], color: color, shade: s),
                TerrainVertex(position: quad[2], uv: uv[2], color: color, shade: s),
                TerrainVertex(position: quad[3], uv: uv[3], color: color, shade: s),
            ])
            return
        }

        // Ambient occlusion per vertex using the face tangent directions.
        // Each vertex checks 3 surrounding solid blocks at the face plane for occlusion.
        let (t1, t2) = faceTangents(face)
        // Corner signs follow the quad vertex order: [(-1,-1),(+1,-1),(+1,+1),(-1,+1)]
        let cornerSigns: [(Int, Int)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        var shades = [Float](repeating: 0, count: 4)
        for i in 0..<4 {
            let (s1, s2) = cornerSigns[i]
            let side1 = faceCenter &+ t1 &* s1
            let side2 = faceCenter &+ t2 &* s2
            let corner = faceCenter &+ t1 &* s1 &+ t2 &* s2
            let ao = aoFactor(side1: side1, side2: side2, corner: corner, in: snapshot)
            shades[i] = face.shade * skyLight * ao
        }

        // Flip quad diagonal when AO is anisotropic to avoid a dark-corner artifact.
        let flip = shades[0] + shades[2] < shades[1] + shades[3]

        let qv0 = TerrainVertex(position: quad[0], uv: uv[0], color: color, shade: shades[0])
        let qv1 = TerrainVertex(position: quad[1], uv: uv[1], color: color, shade: shades[1])
        let qv2 = TerrainVertex(position: quad[2], uv: uv[2], color: color, shade: shades[2])
        let qv3 = TerrainVertex(position: quad[3], uv: uv[3], color: color, shade: shades[3])

        if flip {
            vertices.append(contentsOf: [qv0, qv1, qv3, qv1, qv2, qv3])
        } else {
            vertices.append(contentsOf: [qv0, qv1, qv2, qv0, qv2, qv3])
        }
    }

    // Tangent axes for each face. Combined with corner signs [(-1,-1),(+1,-1),(+1,+1),(-1,+1)]
    // they identify the three AO-neighbor blocks around each quad vertex.
    private static func faceTangents(_ face: BlockFace) -> (SIMD3<Int>, SIMD3<Int>) {
        switch face {
        case .north:  return (SIMD3( 1, 0,  0), SIMD3(0, 1, 0))
        case .south:  return (SIMD3(-1, 0,  0), SIMD3(0, 1, 0))
        case .east:   return (SIMD3( 0, 0,  1), SIMD3(0, 1, 0))
        case .west:   return (SIMD3( 0, 0, -1), SIMD3(0, 1, 0))
        case .top:    return (SIMD3( 1, 0,  0), SIMD3(0, 0, 1))
        case .bottom: return (SIMD3( 1, 0,  0), SIMD3(0, 0,-1))
        }
    }

    private static func hasSkyAccess(worldX: Int, y: Int, worldZ: Int, in snapshot: WorldMeshSnapshot) -> Bool {
        guard y < Chunk.sizeY - 1 else { return true }
        guard y >= 0 else { return false }
        for checkY in (y + 1)..<Chunk.sizeY {
            let block = snapshot.blockAt(worldX: worldX, y: checkY, worldZ: worldZ)
            if block != .air && block != .water && block != .leaves {
                return false
            }
        }
        return true
    }

    private static func aoFactor(side1: SIMD3<Int>, side2: SIMD3<Int>, corner: SIMD3<Int>, in snapshot: WorldMeshSnapshot) -> Float {
        let s1 = isSolidForAO(side1, in: snapshot) ? 1 : 0
        let s2 = isSolidForAO(side2, in: snapshot) ? 1 : 0
        // When both sides are solid the corner is fully occluded regardless.
        let c = (s1 == 1 && s2 == 1) ? 1 : (isSolidForAO(corner, in: snapshot) ? 1 : 0)
        let level = 3 - s1 - s2 - c   // 0 = darkest, 3 = brightest
        switch level {
        case 0:  return 0.50
        case 1:  return 0.70
        case 2:  return 0.85
        default: return 1.00
        }
    }

    private static func isSolidForAO(_ pos: SIMD3<Int>, in snapshot: WorldMeshSnapshot) -> Bool {
        let block = snapshot.blockAt(worldX: pos.x, y: pos.y, worldZ: pos.z)
        return block != .air && block != .water
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
