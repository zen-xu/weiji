import CommonCrypto
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import VideoToolbox

enum ImageDecodeError: String, Error {
    case keyUnavailable = "key_unavailable"
    case invalidData = "invalid_data"
    case unsupported = "unsupported_format"
    case tooLarge = "too_large"
    case decoderUnavailable = "decoder_unavailable"
    case sourceChanged = "source_changed"
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
