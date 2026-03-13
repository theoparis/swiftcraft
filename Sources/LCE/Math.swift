import simd

typealias float4x4 = simd_float4x4
typealias float3 = SIMD3<Float>
typealias float2 = SIMD2<Float>

extension float4x4 {
    init(translation: float3) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
    }

    init(rotationYXZ yaw: Float, pitch: Float) {
        let yawMatrix = float4x4(
            SIMD4<Float>(cos(yaw), 0, -sin(yaw), 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sin(yaw), 0, cos(yaw), 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        let pitchMatrix = float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, cos(pitch), sin(pitch), 0),
            SIMD4<Float>(0, -sin(pitch), cos(pitch), 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        self = yawMatrix * pitchMatrix
    }

    init(perspectiveFov fovY: Float, aspect: Float, nearZ: Float, farZ: Float) {
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / aspect
        let zRange = farZ - nearZ
        let zScale = -(farZ + nearZ) / zRange
        let wzScale = -2 * farZ * nearZ / zRange

        self = float4x4(
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        )
    }

    init(lookFrom eye: float3, forward: float3, up: float3) {
        let z = simd_normalize(-forward)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        let translation = float3(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye))

        self = float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        )
    }
}

func radians(_ degrees: Float) -> Float {
    degrees * .pi / 180
}
