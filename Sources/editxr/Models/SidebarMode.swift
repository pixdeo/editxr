import Foundation

/// What the docked left sidebar shows. Persisted (raw string) in Config.
enum SidebarMode: String {
    case off
    case outline   // document headings (auto-follows the cursor)
    case files     // project file explorer (navigable when focused)
}
