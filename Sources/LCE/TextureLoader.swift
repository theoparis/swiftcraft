import Foundation
import MetalKit

enum TextureLoaderError: Error {
    case textureNotFound
}

enum TextureLoader {
    static func loadTerrainAtlas(device: MTLDevice) throws -> MTLTexture {
        let searchPaths = [
            Bundle.module.url(forResource: "terrain", withExtension: "png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "res")
                .appending(path: "terrain.png"),
            Bundle.main.resourceURL?.appending(path: "terrain.png"),
            Bundle.main.bundleURL.appending(path: "terrain.png")
        ].compactMap { $0 }

        guard let url = searchPaths.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw TextureLoaderError.textureNotFound
        }

        let loader = MTKTextureLoader(device: device)
        return try loader.newTexture(
            URL: url,
            options: [
                MTKTextureLoader.Option.SRGB: false,
                MTKTextureLoader.Option.textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ]
        )
    }
}
