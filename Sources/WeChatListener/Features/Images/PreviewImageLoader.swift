import AppKit
import ImageIO
import SwiftUI

/// Read and decompress cached previews away from SwiftUI's main actor. The cache has a fixed memory budget.
enum PreviewImageLoader {
    static func clearCache() {
        cache.removeAllObjects()
        queue.async { cache.removeAllObjects() }
    }
    private static let queue = DispatchQueue(label: "local.wechat-listener.preview-display", qos: .userInitiated)
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 128
        return cache
    }()
    static func load(_ preview: ImagePreview, paths: AppPaths, name: String = "image.png") async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                let image: CGImage? = autoreleasepool {
                    // Validate even on cache hits so a deleted or replaced cache path is never trusted.
                    guard let url = try? preview.validFile(paths: paths, name: name) else { return nil }
                    let key = url.path as NSString
                    if let cached = cache.object(forKey: key) { return cached }
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                        let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                        let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                        width > 0, height > 0, width <= 4096, height <= 4096,
                        let decoded = CGImageSourceCreateImageAtIndex(
                            source, 0,
                            [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true]
                                as CFDictionary)
                    else { return nil }
                    cache.setObject(decoded, forKey: key, cost: decoded.bytesPerRow * decoded.height)
                    return decoded
                }
                continuation.resume(returning: image)
            }
        }
    }
}
