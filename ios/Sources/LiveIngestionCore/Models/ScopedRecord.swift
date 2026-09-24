import Foundation

/// Any bundle record that carries an applicability `Scope`.
public protocol ScopedRecord {
    var scope: Scope { get }
}

extension TicketRound: ScopedRecord {}
extension GoodsCampaign: ScopedRecord {}
extension MediaAsset: ScopedRecord {}
extension Notice: ScopedRecord {}
