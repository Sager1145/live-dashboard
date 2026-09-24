import Foundation
import LiveIngestionCore

private final class KitBundleToken {}

public extension Bundle {
    /// Resource bundle of LiveDashboardKit for both the SwiftPM build (Bundle.module) and the XcodeGen framework build.
    static let kit: Bundle = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle(for: KitBundleToken.self)
        #endif
    }()
}
