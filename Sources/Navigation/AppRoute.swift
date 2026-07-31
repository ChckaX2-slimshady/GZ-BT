import Foundation

/// Every top-level destination. The Navigation layer owns this; it carries a
/// title and icon for the sidebar but holds no business logic.
enum AppRoute: String, CaseIterable, Identifiable, Hashable {
    case chat, models, hats, prompts, memory, wiki, reader, tools
    case settings
    case osintinel, rsai, spectre

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .models: "Models"
        case .hats: "HATS"
        case .prompts: "Prompts"
        case .memory: "Memory"
        case .wiki: "Knowledge Wiki"
        case .reader: "Reader"
        case .tools: "Tools & MCP"
        case .settings: "Settings"
        case .osintinel: "OSINTINEL"
        case .rsai: "RSAI"
        case .spectre: "Spectre"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .models: "cube"
        case .hats: "theatermasks"
        case .prompts: "text.quote"
        case .memory: "brain"
        case .wiki: "books.vertical"
        case .reader: "doc.richtext"
        case .tools: "wrench.and.screwdriver"
        case .settings: "gearshape"
        case .osintinel: "binoculars"
        case .rsai: "atom"
        case .spectre: "waveform.path.ecg"
        }
    }

    /// Real destinations. Chat/Models/Settings landed in Session 1; **Spectre** is a
    /// live Seam-1 view as of S2.5 (still behind the default-OFF global toggle).
    /// The rest are stubs.
    var isImplemented: Bool {
        switch self {
        case .chat, .models, .settings, .spectre: true
        default: false
        }
    }

    // Sidebar grouping. `.spectre` is appended by the sidebar only when enabled.
    static let workspace: [AppRoute] = [.chat, .models, .hats, .prompts, .memory, .wiki, .reader, .tools]
    static let labs: [AppRoute] = [.osintinel, .rsai]
    static let system: [AppRoute] = [.settings]
}
