import Foundation

public protocol LossyStringEnum: RawRepresentable, Codable where RawValue == String {
    static var fallback: Self { get }
}

public extension LossyStringEnum {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? Self.fallback
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
