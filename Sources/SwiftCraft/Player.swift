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
        let headInWater = world.isWater(
            worldX: Int(floor(eyePosition.x)),
            y: Int(floor(eyePosition.y)),
            worldZ: Int(floor(eyePosition.z))
        )
        let jumpPressed = input.isPressed(Key.space)
        let jumpJustPressed = jumpPressed && !wasJumpPressed
        let isSprinting = input.isPressed(Key.leftShift)

        if isSwimming {
            // Water: friction-impulse with sluggish horizontal movement (~2 m/s swim speed).
            // Decay rate 6/s → equilibrium speed = pushAccel / decayRate.
            let hDecay: Float = 6.0
            let hFriction = exp(-hDecay * dt)
            velocity.x *= hFriction
            velocity.z *= hFriction
            if hasMoveInput {
                let dir = simd_normalize(moveAxis)
                let pushAccel: Float = 2.0 * hDecay  // equilibrium 2.0 m/s
                velocity.x += dir.x * pushAccel * dt
                velocity.z += dir.z * pushAccel * dt
            }

            // At the water surface (head above water), space jumps out like on land.
            if jumpJustPressed && !headInWater {
                velocity.y = 9.5
            } else {
                let vDecay: Float = 3.5
                velocity.y *= exp(-vDecay * dt)

                if headInWater {
                    // Submerged: apply gentle sink and allow swimming up.
                    velocity.y -= 5.0 * dt
                    if jumpPressed {
                        let swimUp: Float = 3.0 * vDecay
                        if velocity.y < 3.0 { velocity.y += swimUp * dt }
                    }
                }
                // At the surface (!headInWater): only drag runs, no sink and no swim-up.
                // This lets the player float without oscillating between water and air physics.

                velocity.y = max(velocity.y, -4.0)
            }

        } else {
            // Ground / air: Beta 1.8.1 friction-impulse model.
            // Friction decay rates: ground ~12/s (snappy), air ~1/s (momentum preserved).
            let hDecay: Float = isGrounded ? 12.0 : 1.0
            let hFriction = exp(-hDecay * dt)
            velocity.x *= hFriction
            velocity.z *= hFriction

            if hasMoveInput {
                let dir = simd_normalize(moveAxis)
                let pushAccel: Float
                if isGrounded {
                    // Walk 4.3 m/s, sprint 5.6 m/s (Beta 1.8.1 exact values).
                    let targetSpeed: Float = isSprinting ? 5.6 : 4.3
                    pushAccel = targetSpeed * hDecay
                } else {
                    // Air control: equilibrium ≈ walk speed so momentum is mostly preserved.
                    pushAccel = 4.3 * hDecay
                }
                velocity.x += dir.x * pushAccel * dt
                velocity.z += dir.z * pushAccel * dt
            }

            // Jump: 0.42 b/tick * 20 tps = 8.4, tuned up slightly for reliable 1-block clearing.
            if isGrounded && jumpJustPressed {
                velocity.y = 9.5
                isGrounded = false
            }

            // Gravity + air drag on Y axis matching Beta's 0.08 grav / 0.98 drag per tick.
            velocity.y -= 32.0 * dt
            velocity.y *= exp(-0.404 * dt)  // pow(0.98, 20) per second
            velocity.y = max(velocity.y, -50.0)
        }

        moveAndCollide(deltaTime: dt, world: world)
        wasJumpPressed = jumpPressed
    }

    private func moveAndCollide(deltaTime dt: Float, world: VoxelWorld) {
        isGrounded = false

        // Save deltas before sweepAxis can zero the velocities.
        let dx = velocity.x * dt
        let dz = velocity.z * dt

        var pos = position
        pos.x = sweepAxis(position: pos, delta: dx, axis: 0, world: world)
        pos.y = sweepAxis(position: pos, delta: velocity.y * dt, axis: 1, world: world)
        pos.z = sweepAxis(position: pos, delta: dz, axis: 2, world: world)

        // Auto-step: when grounded and walking into a ledge ≤ 0.5 blocks tall, step up.
        let xBlocked = abs(dx) > 0.001 && pos.x == position.x
        let zBlocked = abs(dz) > 0.001 && pos.z == position.z
        if isGrounded && (xBlocked || zBlocked) {
            let stepH: Float = 0.5
            var sp = float3(position.x, position.y + stepH, position.z)
            if !collides(at: sp, world: world) {
                var moved = false
                if xBlocked { var tx = sp; tx.x += dx; if !collides(at: tx, world: world) { sp.x = tx.x; moved = true } }
                if zBlocked { var tz = sp; tz.z += dz; if !collides(at: tz, world: world) { sp.z = tz.z; moved = true } }
                if moved {
                    // Snap back down to the ledge surface.
                    var sd = sp; sd.y -= stepH
                    sp.y = collides(at: sd, world: world) ? sp.y : sd.y
                    isGrounded = true
                    velocity.x = dx / dt
                    velocity.z = dz / dt
                    pos = sp
                }
            }
        }

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
            } else if isGrounded {
                // Only kill horizontal velocity when grounded. In the air, momentum is
                // preserved so the player can still jump over the wall they just touched.
                if axis == 0 { velocity.x = 0 } else { velocity.z = 0 }
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
