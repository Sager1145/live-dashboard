import Foundation

public struct LiveStop: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let eventID: String
    public let name: String
    public let order: Int

    public init(id: String, eventID: String, name: String, order: Int) {
        self.id = id
        self.eventID = eventID
        self.name = name
        self.order = order
    }
}
