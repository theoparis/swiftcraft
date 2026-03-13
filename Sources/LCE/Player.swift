import Foundation
import simd

@MainActor
final class PlayerController {
    var position = float3(0, 30, 0)
    var velocity = float3(repeating: 0)
    var yaw: Float = radians(45)
    var pitch: Float = radians(-18)

    let radius: Float = 0.35
    let height: Float = 1.8

    private(set) var isGrounded = false
    private(set) var isSwimming = false
    private var wasJumpPressed = false

    var eyePosition: float3 {
        position + float3(0, 1.62, 0)
    }

    var forward: float3 {
        let x = cos(pitch) * sin(yaw)
        let y = sin(pitch)
        let z = -cos(pitch) * cos(yaw)
        return simd_normalize(float3(x, y, z))
    }

    var right: float3 {
        simd_normalize(simd_cross(forward, float3(0, 1, 0)))
    }

    func update(deltaTime dt: Float, input: InputHandler, world: VoxelWorld) {
        let mouseDelta = input.consumeMouseDelta()
        let sensitivity: Float = 0.0025
        yaw += mouseDelta.x * sensitivity
        pitch -= mouseDelta.y * sensitivity
        pitch = max(radians(-89), min(radians(89), pitch))

        var moveAxis = float3(repeating: 0)
        let flatForward = simd_normalize(float3(forward.x, 0, forward.z))
        let strafe = simd_normalize(float3(right.x, 0, right.z))

        if input.isPressed(Key.w) { moveAxis += flatForward }
        if input.isPressed(Key.s) { moveAxis -= flatForward }
        if input.isPressed(Key.d) { moveAxis += strafe }
        if input.isPressed(Key.a) { moveAxis -= strafe }

        let hasMoveInput = simd_length_squared(moveAxis) > 0.0001
        isSwimming = intersectsWater(at: position, world: world)
        let feetInWater = intersectsWater(at: position + float3(0, 0.05, 0), world: world)
        let headInWater = world.isWater(
            worldX: Int(floor(eyePosition.x)),
            y: Int(floor(eyePosition.y)),
            worldZ: Int(floor(eyePosition.z))
        )
        let jumpPressed = input.isPressed(Key.space)
        let jumpJustPressed = jumpPressed && !wasJumpPressed
        let walkSpeed: Float = isSwimming ? 3.0 : (input.isPressed(Key.leftShift) ? 8.5 : 5.0)
        let acceleration: Float = isSwimming ? 10 : (isGrounded ? 22 : 8)
        let friction: Float = isSwimming ? 5 : (isGrounded ? 12 : 1.5)

        if hasMoveInput {
            moveAxis = simd_normalize(moveAxis)
            let targetVelocity = moveAxis * walkSpeed
            velocity.x = approach(velocity.x, targetVelocity.x, acceleration * dt)
            velocity.z = approach(velocity.z, targetVelocity.z, acceleration * dt)
        } else {
            velocity.x = approach(velocity.x, 0, friction * dt)
            velocity.z = approach(velocity.z, 0, friction * dt)
        }

        if isSwimming {
            if jumpPressed {
                if jumpJustPressed && feetInWater && !headInWater {
                    velocity.y = max(velocity.y, 6.75)
                } else {
                    velocity.y = approach(velocity.y, 4.5, 18 * dt)
                }
            } else {
                velocity.y = approach(velocity.y, 0, 6 * dt)
            }
            velocity.y -= 7.5 * dt
            velocity.y = max(velocity.y, -5.5)
        } else {
            if isGrounded && jumpPressed {
                velocity.y = 6.75
                isGrounded = false
            }

            velocity.y -= 20 * dt
            velocity.y = max(velocity.y, -40)
        }

        moveAndCollide(deltaTime: dt, world: world)
        wasJumpPressed = jumpPressed
    }

    private func moveAndCollide(deltaTime dt: Float, world: VoxelWorld) {
        isGrounded = false

        var pos = position
        pos.x = sweepAxis(position: pos, delta: velocity.x * dt, axis: 0, world: world)
        pos.y = sweepAxis(position: pos, delta: velocity.y * dt, axis: 1, world: world)
        pos.z = sweepAxis(position: pos, delta: velocity.z * dt, axis: 2, world: world)
        position = pos
    }

    private func sweepAxis(position: float3, delta: Float, axis: Int, world: VoxelWorld) -> Float {
        guard delta != 0 else { return position[axis] }
        var testPosition = position
        testPosition[axis] += delta
        if collides(at: testPosition, world: world) {
            if axis == 1 {
                if delta < 0 { isGrounded = true }
                velocity.y = 0
            } else if axis == 0 {
                velocity.x = 0
            } else {
                velocity.z = 0
            }
            return position[axis]
        }
        return testPosition[axis]
    }

    private func collides(at position: float3, world: VoxelWorld) -> Bool {
        let minCorner = position + float3(-radius, 0, -radius)
        let maxCorner = position + float3(radius, height, radius)

        let minX = Int(floor(minCorner.x))
        let maxX = Int(floor(maxCorner.x))
        let minY = Int(floor(minCorner.y))
        let maxY = Int(floor(maxCorner.y))
        let minZ = Int(floor(minCorner.z))
        let maxZ = Int(floor(maxCorner.z))

        for y in minY...maxY {
            for z in minZ...maxZ {
                for x in minX...maxX {
                    if world.isSolid(worldX: x, y: y, worldZ: z) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func intersectsWater(at position: float3, world: VoxelWorld) -> Bool {
        let sampleMin = position + float3(-radius, 0.2, -radius)
        let sampleMax = position + float3(radius, height * 0.9, radius)

        let minX = Int(floor(sampleMin.x))
        let maxX = Int(floor(sampleMax.x))
        let minY = Int(floor(sampleMin.y))
        let maxY = Int(floor(sampleMax.y))
        let minZ = Int(floor(sampleMin.z))
        let maxZ = Int(floor(sampleMax.z))

        for y in minY...maxY {
            for z in minZ...maxZ {
                for x in minX...maxX {
                    if world.isWater(worldX: x, y: y, worldZ: z) {
                        return true
                    }
                }
            }
        }
        return false
    }
}

private func approach(_ current: Float, _ target: Float, _ delta: Float) -> Float {
    if current < target {
        return min(current + delta, target)
    }
    return max(current - delta, target)
}
