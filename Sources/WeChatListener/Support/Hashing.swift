import CryptoKit
import Foundation

private let hexDigits = Array("0123456789abcdef".utf8)
private func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    String(decoding: bytes.flatMap { [hexDigits[Int($0 >> 4)], hexDigits[Int($0 & 15)]] }, as: UTF8.self)
}

func digest(_ value: String) -> String { hexString(SHA256.hash(data: Data(value.utf8))) }

func mediaDirectoryID(_ chat: String) -> String {
    hexString(Insecure.MD5.hash(data: Data(chat.utf8)))
}
