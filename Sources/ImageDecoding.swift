import Foundation
import CryptoKit
import CommonCrypto
import ImageIO
import CoreImage
import VideoToolbox

enum ImageDecodeError: String, Error {
    case keyUnavailable = "key_unavailable", invalidData = "invalid_data", unsupported = "unsupported_format"
    case tooLarge = "too_large", decoderUnavailable = "decoder_unavailable", sourceChanged = "source_changed"
    var label: String {
        switch self {
        case .keyUnavailable: return "暂未找到匹配的本地图片密钥"
        case .invalidData: return "图片数据尚不完整或格式不匹配"
        case .unsupported: return "暂不支持这种图片格式"
        case .tooLarge: return "图片超过预览大小限制"
        case .decoderUnavailable: return "系统暂时无法解码此图片，可重新扫描重试"
        case .sourceChanged: return "源文件已更新，请重新扫描"
        }
    }
}

struct ImageKey {
    let aes: Data
    let xor: UInt8
}

/// Keys are derived from local cache filenames, tested against the actual image, and never persisted or logged.
enum ImageKeys {
    static func directories(account: URL) -> [URL] {
        let documents = account.deletingLastPathComponent().deletingLastPathComponent()
        let container = documents.deletingLastPathComponent()
        return [documents.appendingPathComponent("app_data/net/kvcomm"), documents.appendingPathComponent("xwechat/net/kvcomm"),
                container.appendingPathComponent("Library/Application Support/com.tencent.xinWeChat/xwechat/net/kvcomm"),
                container.appendingPathComponent("Library/Application Support/com.tencent.xinWeChat/net/kvcomm")]
    }
    static func candidates(account: URL) -> [ImageKey] {
        var codes = Set<UInt32>()
        for directory in directories(account: account) {
            guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.prefix(2000) where name.hasPrefix("key_") && name.hasSuffix(".statistic") {
                let parts = name.split(separator: "_")
                if parts.count >= 3, let code = UInt32(parts[1]) { codes.insert(code) }
            }
        }
        let raw = account.lastPathComponent
        let normalized: String
        if raw.lowercased().hasPrefix("wxid_") { normalized = raw.split(separator: "_").prefix(2).joined(separator: "_") }
        else { normalized = raw.replacingOccurrences(of: "_[a-zA-Z0-9]{4}$", with: "", options: .regularExpression) }
        return codes.sorted().flatMap { code in
            Set([raw, normalized]).sorted().map { name in
                let hex = Insecure.MD5.hash(data: Data("\(code)\(name)".utf8)).map { String(format: "%02x", $0) }.joined()
                return ImageKey(aes: Data(hex.prefix(16).utf8), xor: UInt8(code & 255))
            }
        }
    }
}

enum ImageDecoder {
    static let maxBytes = 32 * 1024 * 1024
    static let maxPixels = 40_000_000
    static func crypt(_ data: Data, key: Data, operation: CCOperation = CCOperation(kCCDecrypt), padded: Bool = true) throws -> Data {
        guard key.count == kCCKeySizeAES128, !data.isEmpty, data.count <= maxBytes, data.count % 16 == 0 else { throw ImageDecodeError.invalidData }
        var output = Data(count: data.count + kCCBlockSizeAES128), written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in key.withUnsafeBytes { secret in
            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | (padded ? kCCOptionPKCS7Padding : 0)),
                    secret.baseAddress, key.count, nil, input.baseAddress, data.count, out.baseAddress, capacity, &written)
        } } }
        guard status == kCCSuccess else { throw ImageDecodeError.invalidData }
        output.count = written
        return output
    }
    static func knownFormat(_ bytes: Data) -> Bool {
        bytes.starts(with: [255,216,255]) || bytes.starts(with: [137,80,78,71,13,10,26,10]) ||
        bytes.starts(with: Array("GIF8".utf8)) || bytes.starts(with: Array("wxgf".utf8)) ||
        (bytes.starts(with: Array("RIFF".utf8)) && bytes.count >= 12 && bytes.subdata(in: 8..<12) == Data("WEBP".utf8))
    }
    static func payload(_ data: Data, keys: [ImageKey]) throws -> (Data, String) {
        guard data.count <= maxBytes else { throw ImageDecodeError.tooLarge }
        if knownFormat(data) { return (data, "plain_image") }
        let v2 = data.starts(with: [7,8,86,50,8,7])
        if data.starts(with: [7,8,86,49,8,7]) { throw ImageDecodeError.unsupported }
        if v2 {
            guard data.count >= 31 else { throw ImageDecodeError.invalidData }
            let bytes = [UInt8](data.prefix(15))
            func number(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at+$1]) << ($1*8) } }
            let aesCount = number(6), xorCount = number(10)
            let end = 15 + aesCount + (16 - aesCount % 16), rawEnd = data.count - xorCount
            guard aesCount > 0, end <= rawEnd, rawEnd <= data.count else { throw ImageDecodeError.invalidData }
            for key in keys {
                guard let first = try? crypt(data.subdata(in: 15..<31), key: key.aes, padded: false), knownFormat(first),
                      let prefix = try? crypt(data.subdata(in: 15..<end), key: key.aes), prefix.count == aesCount else { continue }
                var plain = prefix
                plain.append(data.subdata(in: end..<rawEnd)); plain.append(contentsOf: data[rawEnd...].map { $0 ^ key.xor })
                return (plain, "v2_aes_xor")
            }
            throw ImageDecodeError.keyUnavailable
        }
        // Older DAT files use a single XOR byte; magic detection is followed by a full image decode.
        for head: [UInt8] in [[255,216,255], [137,80,78,71,13,10,26,10], Array("GIF89a".utf8), Array("RIFF".utf8)] {
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
              w <= maxPixels / h else { throw ImageDecodeError.invalidData }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else { throw ImageDecodeError.invalidData }
        return image
    }
}

/// WXGF may contain a grayscale mask stream before the color stream. Select a color image, never the mask as the preview.
enum WXGFDecoder {
    static func units(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var starts = [(Int, Int)](), i = 4
        while i + 3 < bytes.count {
            if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 { starts.append((i, 3)); i += 3 }
            else if i+4 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 { starts.append((i, 4)); i += 4 }
            else { i += 1 }
            if starts.count > 1024 { throw ImageDecodeError.tooLarge }
        }
        return starts.enumerated().compactMap { index, start in
            let end = index+1 < starts.count ? starts[index+1].0 : bytes.count
            return start.0 + start.1 + 1 < end ? Data(bytes[(start.0+start.1)..<end]) : nil
        }
    }
    static func kind(_ unit: Data) -> Int { Int((unit.first! >> 1) & 63) }
    static func chromaFormat(_ sps: Data) -> Int? {
        var rbsp = [UInt8](), zeros = 0
        for byte in sps.dropFirst(2) {
            if zeros >= 2 && byte == 3 { zeros = 0; continue }
            rbsp.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        var bit = 0
        func read(_ count: Int) -> Int? {
            guard count >= 0, bit + count <= rbsp.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count { value = (value << 1) | Int((rbsp[bit / 8] >> (7-bit % 8)) & 1); bit += 1 }
            return value
        }
        func skip(_ count: Int) -> Bool { guard bit+count <= rbsp.count*8 else { return false }; bit += count; return true }
        func ue() -> Int? {
            var zeros = 0
            while let b = read(1) { if b == 1 { guard let suffix = read(zeros) else { return nil }; return (1 << zeros)-1+suffix }; zeros += 1; if zeros > 20 { return nil } }
            return nil
        }
        guard read(4) != nil, let layers = read(3), read(1) != nil, skip(96) else { return nil }
        var flags = [(Int,Int)]()
        for _ in 0..<layers { guard let profile = read(1), let level = read(1) else { return nil }; flags.append((profile,level)) }
        if layers > 0 && !skip((8-layers)*2) { return nil }
        for (profile,level) in flags {
            if profile == 1 && !skip(88) { return nil }
            if level == 1 && !skip(8) { return nil }
        }
        guard ue() != nil else { return nil }
        return ue()
    }
    static func decode(_ data: Data) throws -> CGImage {
        var groups = [[Data]]()
        for unit in try units(data) {
            if kind(unit) == 32 { groups.append([]) }
            if !groups.isEmpty { groups[groups.count-1].append(unit) }
            if groups.count > 16 { throw ImageDecodeError.tooLarge }
        }
        let color = groups.filter { group in group.first(where: { kind($0) == 33 }).flatMap(chromaFormat).map({ $0 > 0 }) == true }
        // For static previews use a color stream; grayscale-only images remain valid when no color stream exists.
        for group in (color.isEmpty ? groups : color).reversed() {
            if let image = try? frame(group) { return image }
        }
        throw ImageDecodeError.decoderUnavailable
    }
    private final class FrameBox { var image: CVImageBuffer?; var status: OSStatus = 0 }
    static func frame(_ units: [Data]) throws -> CGImage {
        guard let vps = units.first(where: { kind($0) == 32 }), let sps = units.first(where: { kind($0) == 33 }),
              let pps = units.first(where: { kind($0) == 34 }), units.contains(where: { kind($0) <= 31 }) else { throw ImageDecodeError.invalidData }
        var description: CMFormatDescription?
        let status = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
            let ptrs = [v.baseAddress!.assumingMemoryBound(to: UInt8.self), s.baseAddress!.assumingMemoryBound(to: UInt8.self), p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
            return ptrs.withUnsafeBufferPointer { buf in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3,
                    parameterSetPointers: buf.baseAddress!, parameterSetSizes: [vps.count,sps.count,pps.count], nalUnitHeaderLength: 4,
                    extensions: nil, formatDescriptionOut: &description)
            }
        } } }
        guard status == noErr, let description else { throw ImageDecodeError.invalidData }
        let size = CMVideoFormatDescriptionGetDimensions(description)
        guard size.width > 0, size.height > 0, Int(size.width) <= ImageDecoder.maxPixels / Int(size.height) else { throw ImageDecodeError.tooLarge }
        let box = FrameBox()
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref,_,status,_,image,_,_ in
            guard let ref else { return }; let box = Unmanaged<FrameBox>.fromOpaque(ref).takeUnretainedValue()
            box.status = status; box.image = image
        }, decompressionOutputRefCon: Unmanaged.passUnretained(box).toOpaque())
        var session: VTDecompressionSession?
        let rc = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false] as CFDictionary,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &session)
        guard rc == noErr, let session else { throw ImageDecodeError.decoderUnavailable }
        defer { VTDecompressionSessionInvalidate(session) }
        var sampleData = Data()
        for unit in units where ![32,33,34].contains(kind(unit)) {
            var size = UInt32(unit.count).bigEndian; withUnsafeBytes(of: &size) { sampleData.append(contentsOf: $0) }; sampleData.append(unit)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: sampleData.count, flags: 0,
            blockBufferOut: &block) == noErr, let block else { throw ImageDecodeError.invalidData }
        guard sampleData.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
            dataLength: sampleData.count) }) == noErr else { throw ImageDecodeError.invalidData }
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: [sampleData.count],
            sampleBufferOut: &sample) == noErr, let sample else { throw ImageDecodeError.invalidData }
        let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        VTDecompressionSessionFinishDelayedFrames(session); VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard result == noErr, box.status == noErr, let buffer = box.image else { throw ImageDecodeError.decoderUnavailable }
        let ci = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 4096 / max(ci.extent.width, ci.extent.height))
        let resized = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = CIContext().createCGImage(resized, from: resized.extent) else { throw ImageDecodeError.invalidData }
        return image
    }
}
