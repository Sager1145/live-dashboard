import SwiftUI

public extension View {
    /// Animates `value` changes with a snappy spring unless Reduce Motion is on (then no animation).
    func motionAnimation<V: Equatable>(_ value: V) -> some View { modifier(MotionAnimationModifier(value: value)) }
}

struct MotionAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V
    func body(content: Content) -> some View { content.animation(reduceMotion ? nil : .snappy, value: value) }
}
