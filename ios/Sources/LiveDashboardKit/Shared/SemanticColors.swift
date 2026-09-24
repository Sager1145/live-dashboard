import SwiftUI
import LiveIngestionCore

public extension Color {
    static let statusPositive = Color("StatusPositive", bundle: .kit)
    static let statusWarning = Color("StatusWarning", bundle: .kit)
    static let statusCritical = Color("StatusCritical", bundle: .kit)
    static let statusInfo = Color("StatusInfo", bundle: .kit)
    static let importanceHighBackground = Color("ImportanceHighBackground", bundle: .kit)
}

/// Leading-dot access in `foregroundStyle`, `tint`, `fill`, etc.
public extension ShapeStyle where Self == Color {
    static var statusPositive: Color { Color.statusPositive }
    static var statusWarning: Color { Color.statusWarning }
    static var statusCritical: Color { Color.statusCritical }
    static var statusInfo: Color { Color.statusInfo }
    static var importanceHighBackground: Color { Color.importanceHighBackground }
}
