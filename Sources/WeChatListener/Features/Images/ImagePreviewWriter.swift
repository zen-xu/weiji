import Foundation
import ImageIO

enum ImagePreviewWriter {
    static func write(_ image: CGImage, to url: URL, type: String, maximum: Int = 4096) throws {
        let scale = min(1, Double(maximum) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard
            let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ImageDecodeError.invalidData }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let resized = context.makeImage() else { throw ImageDecodeError.invalidData }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw ImageDecodeError.invalidData
        }
        CGImageDestinationAddImage(
            destination, resized, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 16 * 1024 * 1024 else {
            throw ImageDecodeError.tooLarge
        }
        try (data as Data).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
