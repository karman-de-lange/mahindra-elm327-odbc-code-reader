import Foundation

public enum FaultStatus: String, Equatable, Hashable {
    case stored
    case pending
    case permanent
    case history

    public var title: String {
        switch self {
        case .stored: return "Stored"
        case .pending: return "Pending"
        case .permanent: return "Permanent"
        case .history: return "Since last clear"
        }
    }
}

public struct FaultCode: Identifiable, Equatable, Hashable {
    public let code: String
    public let status: FaultStatus
    public let moduleID: String?
    public let moduleName: String
    public let summary: String
    public let detail: String

    public var id: String { "\(status.rawValue)|\(moduleID ?? "-")|\(code)" }
}

public struct FaultRead: Equatable {
    public var codes: [FaultCode]
    public var noData: Bool
    public var linkFailed: Bool
    public var rejected: [String]
}

public struct MonitorStatus: Equatable {
    public let milOn: Bool
    public let storedCodeCount: Int
}
