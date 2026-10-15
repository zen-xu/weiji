import CommonCrypto
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import VideoToolbox

enum ImageDecoder {
    static let maxBytes = 32 * 1024 * 1024
    static let maxPixels = 40_000_000
    static func crypt(_ data: Data, key: Data, operation: CCOperation = CCOperation(kCCDecrypt), padded: Bool = true)
        throws -> Data
    {
        guard key.count == kCCKeySizeAES128, !data.isEmpty, data.count <= maxBytes, data.count % 16 == 0 else {
            throw ImageDecodeError.invalidData
        }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { secret in
                    CCCrypt(
                        operation, CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | (padded ? kCCOptionPKCS7Padding : 0)),
                        secret.baseAddress, key.count, nil, input.baseAddress, data.count, out.baseAddress, capacity,
                        &written)
                }
            }
        }
        guard status == kCCSuccess else { throw ImageDecodeError.invalidData }
        output.count = written
        return output
    }
    static func knownFormat(_ bytes: Data) -> Bool {
        bytes.starts(with: [255, 216, 255]) || bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            || bytes.starts(with: Array("GIF8".utf8)) || bytes.starts(with: Array("wxgf".utf8))
            || (bytes.starts(with: Array("RIFF".utf8)) && bytes.count >= 12
                && bytes.subdata(in: 8..<12) == Data("WEBP".utf8))
    }
    static func payload(_ data: Data, keys: [ImageKey]) throws -> (Data, String) {
        guard data.count <= maxBytes else { throw ImageDecodeError.tooLarge }
        if knownFormat(data) { return (data, "plain_image") }
        let v2 = data.starts(with: [7, 8, 86, 50, 8, 7])
        if data.starts(with: [7, 8, 86, 49, 8, 7]) { throw ImageDecodeError.unsupported }
        if v2 {
            guard data.count >= 31 else { throw ImageDecodeError.invalidData }
            let bytes = [UInt8](data.prefix(15))
            func number(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << ($1 * 8) } }
            let aesCount = number(6)
            let xorCount = number(10)
            let end = 15 + aesCount + (16 - aesCount % 16)
            let rawEnd = data.count - xorCount
            guard aesCount > 0, end <= rawEnd, rawEnd <= data.count else { throw ImageDecodeError.invalidData }
            for key in keys {
                guard let first = try? crypt(data.subdata(in: 15..<31), key: key.aes, padded: false),
                    knownFormat(first),
                    let prefix = try? crypt(data.subdata(in: 15..<end), key: key.aes), prefix.count == aesCount
                else { continue }
                var plain = prefix
                plain.append(data.subdata(in: end..<rawEnd))
                plain.append(contentsOf: data[rawEnd...].map { $0 ^ key.xor })
                return (plain, "v2_aes_xor")
            }
            throw ImageDecodeError.keyUnavailable
        }
        // Older DAT files use a single XOR byte; magic detection is followed by a full image decode.
        for head: [UInt8] in [
            [255, 216, 255], [137, 80, 78, 71, 13, 10, 26, 10], Array("GIF89a".utf8), Array("RIFF".utf8),
        ] {
            guard let first = data.first, data.count >= head.count else { continue }
            let key = first ^ head[0]
            if zip(data.prefix(head.count), head).allSatisfy({ $0.0 ^ key == $0.1 }) {
                return (Data(data.map { $0 ^ key }), "legacy_xor")
            }
        }
        throw ImageDecodeError.unsupported
    }
    static func image(_ payload: Data) throws -> CGImage {
        if payload.starts(with: Array("wxgf".utf8)) { return try WXGFDecoder.decode(payload) }
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let w = properties[kCGImagePropertyPixelWidth as String] as? Int,
            let h = properties[kCGImagePropertyPixelHeight as String] as? Int, w > 0, h > 0,
            w <= maxPixels / h
        else { throw ImageDecodeError.invalidData }
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096,
                ] as CFDictionary)
        else { throw ImageDecodeError.invalidData }
        return image
    }
}
