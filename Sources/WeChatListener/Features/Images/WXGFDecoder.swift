import CommonCrypto
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import VideoToolbox

/// WXGF may contain a grayscale mask stream before the color stream. Select a color image, never the mask as the preview.
enum WXGFDecoder {
    static func units(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var starts = [(Int, Int)]()
        var i = 4
        while i + 3 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                starts.append((i, 3))
                i += 3
            } else if i + 4 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0
                && bytes[i + 3] == 1
            {
                starts.append((i, 4))
                i += 4
            } else {
                i += 1
            }
            if starts.count > 1024 { throw ImageDecodeError.tooLarge }
        }
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            return start.0 + start.1 + 1 < end ? Data(bytes[(start.0 + start.1)..<end]) : nil
        }
    }
    static func kind(_ unit: Data) -> Int { Int((unit.first! >> 1) & 63) }
    static func chromaFormat(_ sps: Data) -> Int? {
        var rbsp = [UInt8]()
        var zeros = 0
        for byte in sps.dropFirst(2) {
            if zeros >= 2 && byte == 3 {
                zeros = 0
                continue
            }
            rbsp.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        var bit = 0
        func read(_ count: Int) -> Int? {
            guard count >= 0, bit + count <= rbsp.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | Int((rbsp[bit / 8] >> (7 - bit % 8)) & 1)
                bit += 1
            }
            return value
        }
        func skip(_ count: Int) -> Bool {
            guard bit + count <= rbsp.count * 8 else { return false }
            bit += count
            return true
        }
        func ue() -> Int? {
            var zeros = 0
            while let b = read(1) {
                if b == 1 {
                    guard let suffix = read(zeros) else { return nil }
                    return (1 << zeros) - 1 + suffix
                }
                zeros += 1
                if zeros > 20 { return nil }
            }
            return nil
        }
        guard read(4) != nil, let layers = read(3), read(1) != nil, skip(96) else { return nil }
        var flags = [(Int, Int)]()
        for _ in 0..<layers {
            guard let profile = read(1), let level = read(1) else { return nil }
            flags.append((profile, level))
        }
        if layers > 0 && !skip((8 - layers) * 2) { return nil }
        for (profile, level) in flags {
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
            if !groups.isEmpty { groups[groups.count - 1].append(unit) }
            if groups.count > 16 { throw ImageDecodeError.tooLarge }
        }
        let color = groups.filter { group in
            group.first(where: { kind($0) == 33 }).flatMap(chromaFormat).map({ $0 > 0 }) == true
        }
        // For static previews use a color stream; grayscale-only images remain valid when no color stream exists.
        for group in (color.isEmpty ? groups : color).reversed() {
            if let image = try? frame(group) { return image }
        }
        throw ImageDecodeError.decoderUnavailable
    }
    private final class FrameBox {
        var image: CVImageBuffer?
        var status: OSStatus = 0
    }
    static func frame(_ units: [Data]) throws -> CGImage {
        guard let vps = units.first(where: { kind($0) == 32 }), let sps = units.first(where: { kind($0) == 33 }),
            let pps = units.first(where: { kind($0) == 34 }), units.contains(where: { kind($0) <= 31 })
        else { throw ImageDecodeError.invalidData }
        var description: CMFormatDescription?
        let status = vps.withUnsafeBytes { v in
            sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let ptrs = [
                        v.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        s.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        p.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    return ptrs.withUnsafeBufferPointer { buf in
                        CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 3,
                            parameterSetPointers: buf.baseAddress!,
                            parameterSetSizes: [vps.count, sps.count, pps.count], nalUnitHeaderLength: 4,
                            extensions: nil, formatDescriptionOut: &description)
                    }
                }
            }
        }
        guard status == noErr, let description else { throw ImageDecodeError.invalidData }
        let size = CMVideoFormatDescriptionGetDimensions(description)
        guard size.width > 0, size.height > 0, Int(size.width) <= ImageDecoder.maxPixels / Int(size.height) else {
            throw ImageDecodeError.tooLarge
        }
        let box = FrameBox()
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { ref, _, status, _, image, _, _ in
                guard let ref else { return }
                let box = Unmanaged<FrameBox>.fromOpaque(ref).takeUnretainedValue()
                box.status = status
                box.image = image
            }, decompressionOutputRefCon: Unmanaged.passUnretained(box).toOpaque())
        var session: VTDecompressionSession?
        let rc = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false]
                as CFDictionary,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &session)
        guard rc == noErr, let session else { throw ImageDecodeError.decoderUnavailable }
        defer { VTDecompressionSessionInvalidate(session) }
        var sampleData = Data()
        for unit in units where ![32, 33, 34].contains(kind(unit)) {
            var size = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &size) { sampleData.append(contentsOf: $0) }
            sampleData.append(unit)
        }
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sampleData.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: sampleData.count, flags: 0,
                blockBufferOut: &block) == noErr, let block
        else { throw ImageDecodeError.invalidData }
        guard
            sampleData.withUnsafeBytes({
                CMBlockBufferReplaceDataBytes(
                    with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                    dataLength: sampleData.count)
            }) == noErr
        else { throw ImageDecodeError.invalidData }
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: 1,
                sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                sampleSizeArray: [sampleData.count],
                sampleBufferOut: &sample) == noErr, let sample
        else { throw ImageDecodeError.invalidData }
        let result = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        VTDecompressionSessionFinishDelayedFrames(session)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard result == noErr, box.status == noErr, let buffer = box.image else {
            throw ImageDecodeError.decoderUnavailable
        }
        let ci = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 4096 / max(ci.extent.width, ci.extent.height))
        let resized = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = CIContext().createCGImage(resized, from: resized.extent) else {
            throw ImageDecodeError.invalidData
        }
        return image
    }
}
