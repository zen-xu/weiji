import Foundation

func jsonData<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting =
        pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: jsonData(value)) }
