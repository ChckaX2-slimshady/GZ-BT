import SwiftUI

/// Restrained Veiled Chameleon type scale. Rounded for display/title (organic,
/// shell-like), system for reading text, monospaced for metrics.
enum ChameleonType {
    static let display  = Font.system(size: 32, weight: .semibold, design: .rounded)
    static let title    = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let headline = Font.system(size: 17, weight: .semibold)
    static let body     = Font.system(size: 16, weight: .regular)
    static let callout  = Font.system(size: 14, weight: .regular)
    static let caption  = Font.system(size: 12, weight: .medium)
    static let mono     = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}
