import Foundation

/// The four top-level sections of the Phase-0 shell.
public enum NavigationItem: String, CaseIterable, Hashable, Identifiable, Sendable {
    case inbox, approvals, activity, crm, outreach, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .approvals: return "Approvals"
        case .activity: return "Activity"
        case .crm: return "CRM"
        case .outreach: return "Outreach"
        case .settings: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .inbox: return "tray.and.arrow.down"
        case .approvals: return "checkmark.seal"
        case .activity: return "list.bullet.rectangle"
        case .crm: return "person.3.sequence"
        case .outreach: return "paperplane"
        case .settings: return "gearshape"
        }
    }
}
