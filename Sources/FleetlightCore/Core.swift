import Foundation

public enum HostState: String, Codable, Sendable {
    case checking
    case online
    case waking
    case unreachable
}

public enum FleetlightVersion {
    public static func displayLabel(version: String?, build: String?) -> String {
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = build?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)):
            return "v\(version) (\(build))"
        case let (.some(version), .none):
            return "v\(version)"
        case let (.none, .some(build)):
            return "Build \(build)"
        case (.none, .none):
            return "Development"
        }
    }

    public static var currentDisplayLabel: String {
        displayLabel(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}

public enum FleetObserver {
    public static func displayName(localizedName: String?, hostname: String?) -> String {
        for candidate in [localizedName, hostname] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return trimmed.split(separator: ".", maxSplits: 1).first.map(String.init) ?? trimmed
        }
        return "This Mac"
    }

    public static var currentDisplayName: String {
        displayName(
            localizedName: Host.current().localizedName,
            hostname: ProcessInfo.processInfo.hostName
        )
    }
}

public enum ServiceState: String, Codable, Sendable {
    case healthy
    case degraded
    case stopped
    case unavailable

    public var needsAttention: Bool { self != .healthy }
}

public enum ServiceKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case tailscale
    case docker
    case plex
    case samba

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tailscale: "Tailscale"
        case .docker: "Docker"
        case .plex: "Plex"
        case .samba: "Samba"
        }
    }

    public var systemImage: String {
        switch self {
        case .tailscale: "point.3.connected.trianglepath.dotted"
        case .docker: "shippingbox"
        case .plex: "play.rectangle"
        case .samba: "externaldrive.connected.to.line.below"
        }
    }
}

public struct ServiceSnapshot: Identifiable, Equatable, Sendable {
    public let kind: ServiceKind
    public let state: ServiceState
    public let detail: String

    public var id: String { kind.rawValue }

    public init(kind: ServiceKind, state: ServiceState, detail: String) {
        self.kind = kind
        self.state = state
        self.detail = detail
    }
}

public struct SSHRoute: Identifiable, Hashable, Codable, Sendable {
    public let alias: String
    public let displayName: String

    public var id: String { alias }

    public init(alias: String, displayName: String) {
        self.alias = alias
        self.displayName = displayName
    }
}

public struct FleetHost: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let systemImage: String
    public let isLocal: Bool
    public let wakeMACAddress: String?
    public let wakeBroadcastAddress: String?
    public let supportsCodexDesktopApp: Bool
    public let supportsLinuxUpdates: Bool
    public let services: [ServiceKind]
    public let routes: [SSHRoute]

    public init(
        id: String,
        displayName: String,
        systemImage: String,
        isLocal: Bool = false,
        wakeMACAddress: String? = nil,
        wakeBroadcastAddress: String? = nil,
        supportsCodexDesktopApp: Bool = false,
        supportsLinuxUpdates: Bool = false,
        services: [ServiceKind] = [],
        routes: [SSHRoute] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.systemImage = systemImage
        self.isLocal = isLocal
        self.wakeMACAddress = wakeMACAddress
        self.wakeBroadcastAddress = wakeBroadcastAddress
        self.supportsCodexDesktopApp = supportsCodexDesktopApp
        self.supportsLinuxUpdates = supportsLinuxUpdates
        self.services = services
        self.routes = routes.isEmpty
            ? [SSHRoute(alias: isLocal ? "local" : id, displayName: isLocal ? "Local process" : "Direct")]
            : routes
    }

    public var canWake: Bool { wakeMACAddress != nil }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case systemImage
        case isLocal
        case wakeMACAddress
        case wakeBroadcastAddress
        case supportsCodexDesktopApp = "codexDesktopApp"
        case supportsLinuxUpdates = "linuxUpdates"
        case services
        case routes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let isLocal = try container.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false
        self.init(
            id: id,
            displayName: displayName,
            systemImage: try container.decodeIfPresent(String.self, forKey: .systemImage)
                ?? (isLocal ? "laptopcomputer" : "desktopcomputer"),
            isLocal: isLocal,
            wakeMACAddress: try container.decodeIfPresent(String.self, forKey: .wakeMACAddress),
            wakeBroadcastAddress: try container.decodeIfPresent(String.self, forKey: .wakeBroadcastAddress),
            supportsCodexDesktopApp: try container.decodeIfPresent(Bool.self, forKey: .supportsCodexDesktopApp) ?? false,
            supportsLinuxUpdates: try container.decodeIfPresent(Bool.self, forKey: .supportsLinuxUpdates) ?? false,
            services: try container.decodeIfPresent([ServiceKind].self, forKey: .services) ?? [],
            routes: try container.decodeIfPresent([SSHRoute].self, forKey: .routes) ?? []
        )
    }

    public static let defaults: [FleetHost] = [
        FleetHost(
            id: "local",
            displayName: "This Mac",
            systemImage: "laptopcomputer",
            isLocal: true,
            supportsCodexDesktopApp: true
        ),
    ]

    public static func resolvingLocalHost(in hosts: [FleetHost], hostname: String) -> [FleetHost] {
        resolvingLocalHost(in: hosts, hostnames: [hostname])
    }

    public static func resolvingLocalHost(in hosts: [FleetHost]) -> [FleetHost] {
        resolvingLocalHost(
            in: hosts,
            hostnames: [
                Host.current().localizedName,
                Host.current().name,
                ProcessInfo.processInfo.hostName,
            ].compactMap { $0 }
        )
    }

    public static func resolvingLocalHost(in hosts: [FleetHost], hostnames: [String]) -> [FleetHost] {
        let normalizedHostnames = Set(hostnames.map(normalizedHostIdentifier).filter { !$0.isEmpty })
        guard let localHostID = hosts.first(where: {
            normalizedHostnames.contains(normalizedHostIdentifier($0.id))
        })?.id else {
            return hosts
        }

        return hosts.map { host in
            let isLocal = host.id == localHostID
            let remoteRoutes = host.routes.filter { $0.alias != "local" }
            let displayName: String
            if isLocal {
                displayName = "This Mac"
            } else if host.isLocal && host.displayName == "This Mac" {
                displayName = friendlyHostName(host.id)
            } else {
                displayName = host.displayName
            }
            return FleetHost(
                id: host.id,
                displayName: displayName,
                systemImage: host.systemImage,
                isLocal: isLocal,
                wakeMACAddress: host.wakeMACAddress,
                wakeBroadcastAddress: host.wakeBroadcastAddress,
                supportsCodexDesktopApp: host.supportsCodexDesktopApp,
                supportsLinuxUpdates: host.supportsLinuxUpdates,
                services: host.services,
                routes: isLocal ? [] : remoteRoutes
            )
        }
    }

    private static func normalizedHostIdentifier(_ value: String) -> String {
        let shortName = value
            .lowercased()
            .split(separator: ".", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        return shortName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func friendlyHostName(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

public struct FleetConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public let hosts: [FleetHost]

    public init(version: Int = 1, hosts: [FleetHost]) {
        self.version = version
        self.hosts = hosts
    }

    public static let `default` = FleetConfiguration(hosts: FleetHost.defaults)

    public var validationErrors: [String] {
        var errors: [String] = []
        if version != 1 { errors.append("Unsupported configuration version: \(version)") }
        if hosts.isEmpty { errors.append("At least one machine is required") }

        let hostIDs = hosts.map(\.id)
        if Set(hostIDs).count != hostIDs.count { errors.append("Machine IDs must be unique") }
        if hosts.contains(where: { $0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            errors.append("Machine IDs cannot be empty")
        }
        if hosts.filter(\.isLocal).count > 1 { errors.append("Only one machine can be local") }

        for host in hosts {
            let aliases = host.routes.map(\.alias)
            if Set(aliases).count != aliases.count {
                errors.append("SSH route aliases for \(host.id) must be unique")
            }
        }
        return errors
    }
}

public struct HostSnapshot: Sendable, Equatable {
    public var state: HostState
    public var checkedAt: Date?
    public var pingMilliseconds: Int?
    public var pingMinimumMilliseconds: Int?
    public var pingMaximumMilliseconds: Int?
    public var pingJitterMilliseconds: Int?
    public var packetLossPercent: Double?
    public var latencyMilliseconds: Int?
    public var probeDurationMilliseconds: Int?
    public var operatingSystem: String?
    public var bootDescription: String?
    public var codexVersion: String?
    public var codexDesktopAppVersion: String?
    public var codexDesktopAppBuild: String?
    public var diskPercent: Int?
    public var memoryPercent: Int?
    public var loadAverage: Double?
    public var routeName: String?
    public var routeAlias: String?
    public var services: [ServiceSnapshot]
    public var detail: String

    public init(
        state: HostState = .checking,
        checkedAt: Date? = nil,
        pingMilliseconds: Int? = nil,
        pingMinimumMilliseconds: Int? = nil,
        pingMaximumMilliseconds: Int? = nil,
        pingJitterMilliseconds: Int? = nil,
        packetLossPercent: Double? = nil,
        latencyMilliseconds: Int? = nil,
        probeDurationMilliseconds: Int? = nil,
        operatingSystem: String? = nil,
        bootDescription: String? = nil,
        codexVersion: String? = nil,
        codexDesktopAppVersion: String? = nil,
        codexDesktopAppBuild: String? = nil,
        diskPercent: Int? = nil,
        memoryPercent: Int? = nil,
        loadAverage: Double? = nil,
        routeName: String? = nil,
        routeAlias: String? = nil,
        services: [ServiceSnapshot] = [],
        detail: String = "Waiting for first check"
    ) {
        self.state = state
        self.checkedAt = checkedAt
        self.pingMilliseconds = pingMilliseconds
        self.pingMinimumMilliseconds = pingMinimumMilliseconds
        self.pingMaximumMilliseconds = pingMaximumMilliseconds
        self.pingJitterMilliseconds = pingJitterMilliseconds
        self.packetLossPercent = packetLossPercent
        self.latencyMilliseconds = latencyMilliseconds
        self.probeDurationMilliseconds = probeDurationMilliseconds
        self.operatingSystem = operatingSystem
        self.bootDescription = bootDescription
        self.codexVersion = codexVersion
        self.codexDesktopAppVersion = codexDesktopAppVersion
        self.codexDesktopAppBuild = codexDesktopAppBuild
        self.diskPercent = diskPercent
        self.memoryPercent = memoryPercent
        self.loadAverage = loadAverage
        self.routeName = routeName
        self.routeAlias = routeAlias
        self.services = services
        self.detail = detail
    }

    public var needsAttention: Bool {
        state == .unreachable
            || (diskPercent ?? 0) >= 90
            || services.contains(where: { $0.state.needsAttention })
    }

    public var probeWorkMilliseconds: Int? {
        guard let ready = latencyMilliseconds,
              let total = probeDurationMilliseconds,
              total >= ready else { return nil }
        return total - ready
    }

    public var connectionReadyMilliseconds: Int? {
        latencyMilliseconds
    }
}

public struct FleetServiceEntry: Identifiable, Equatable, Sendable {
    public let hostID: String
    public let hostName: String
    public let kind: ServiceKind
    public let state: ServiceState
    public let detail: String
    public let checkedAt: Date?

    public var id: String { "\(hostID):\(kind.rawValue)" }

    public init(
        hostID: String,
        hostName: String,
        kind: ServiceKind,
        state: ServiceState,
        detail: String,
        checkedAt: Date? = nil
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.kind = kind
        self.state = state
        self.detail = detail
        self.checkedAt = checkedAt
    }
}

public enum FleetServiceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case healthy
    case attention
    case unavailable

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All"
        case .healthy: "Healthy"
        case .attention: "Attention"
        case .unavailable: "Unavailable"
        }
    }
}

public struct FleetServiceSummary: Equatable, Sendable {
    public let healthyCount: Int
    public let attentionCount: Int
    public let unavailableCount: Int

    public init(healthyCount: Int, attentionCount: Int, unavailableCount: Int) {
        self.healthyCount = healthyCount
        self.attentionCount = attentionCount
        self.unavailableCount = unavailableCount
    }
}

public enum FleetServiceAnalyzer {
    public static func entries(
        hosts: [FleetHost],
        snapshots: [String: HostSnapshot]
    ) -> [FleetServiceEntry] {
        hosts.flatMap { host in
            let snapshot = snapshots[host.id] ?? HostSnapshot()
            return host.services.map { kind in
                if snapshot.state == .online,
                   let service = snapshot.services.first(where: { $0.kind == kind }) {
                    return FleetServiceEntry(
                        hostID: host.id,
                        hostName: host.displayName,
                        kind: kind,
                        state: service.state,
                        detail: service.detail,
                        checkedAt: snapshot.checkedAt
                    )
                }

                let detail: String
                if snapshot.state == .online {
                    detail = "No service result returned"
                } else {
                    detail = switch FleetConnectionClassifier.status(for: snapshot) {
                    case .pending: "Waiting for machine check"
                    case .accessIssue: "Monitoring access issue"
                    case .offline: "Machine offline"
                    case .online: "No service result returned"
                    }
                }
                return FleetServiceEntry(
                    hostID: host.id,
                    hostName: host.displayName,
                    kind: kind,
                    state: .unavailable,
                    detail: detail,
                    checkedAt: snapshot.checkedAt
                )
            }
        }.sorted { left, right in
            if left.kind != right.kind {
                return left.kind.displayName.localizedCaseInsensitiveCompare(right.kind.displayName) == .orderedAscending
            }
            let leftRank = stateRank(left.state)
            let rightRank = stateRank(right.state)
            if leftRank != rightRank { return leftRank < rightRank }
            return left.hostName.localizedCaseInsensitiveCompare(right.hostName) == .orderedAscending
        }
    }

    public static func summarize(entries: [FleetServiceEntry]) -> FleetServiceSummary {
        FleetServiceSummary(
            healthyCount: entries.filter { $0.state == .healthy }.count,
            attentionCount: entries.filter { $0.state == .degraded || $0.state == .stopped }.count,
            unavailableCount: entries.filter { $0.state == .unavailable }.count
        )
    }

    public static func filtered(
        entries: [FleetServiceEntry],
        by filter: FleetServiceFilter
    ) -> [FleetServiceEntry] {
        entries.filter { matches(entry: $0, filter: filter) }
    }

    public static func matches(entry: FleetServiceEntry, filter: FleetServiceFilter) -> Bool {
        switch filter {
        case .all:
            true
        case .healthy:
            entry.state == .healthy
        case .attention:
            entry.state == .degraded || entry.state == .stopped
        case .unavailable:
            entry.state == .unavailable
        }
    }

    private static func stateRank(_ state: ServiceState) -> Int {
        switch state {
        case .stopped: 0
        case .degraded: 1
        case .unavailable: 2
        case .healthy: 3
        }
    }
}

public enum FleetServiceReportBuilder {
    public static func build(
        entries: [FleetServiceEntry],
        generatedAt: Date = Date(),
        observerName: String = FleetObserver.currentDisplayName,
        appVersion: String = FleetlightVersion.currentDisplayLabel
    ) -> String {
        let summary = FleetServiceAnalyzer.summarize(entries: entries)
        var lines = [
            "Fleetlight service report — \(generatedAt.formatted(date: .abbreviated, time: .standard))",
            "Observer: \(observerName) · Fleetlight \(appVersion)",
            "Configured \(entries.count) · Healthy \(summary.healthyCount) · Attention \(summary.attentionCount) · Unavailable \(summary.unavailableCount)",
        ]

        if entries.isEmpty {
            lines.append("No configured service checks")
            return lines.joined(separator: "\n")
        }

        for kind in ServiceKind.allCases {
            let serviceEntries = entries.filter { $0.kind == kind }
            guard !serviceEntries.isEmpty else { continue }
            let healthyCount = serviceEntries.filter { $0.state == .healthy }.count
            lines.append("")
            lines.append("\(kind.displayName) — \(healthyCount)/\(serviceEntries.count) healthy")
            for entry in serviceEntries {
                var facts = ["\(entry.state.rawValue.capitalized)", entry.detail]
                if let checkedAt = entry.checkedAt {
                    facts.append("checked \(checkedAt.formatted(date: .abbreviated, time: .standard))")
                } else {
                    facts.append("not yet checked")
                }
                lines.append("• \(entry.hostName) [\(entry.hostID)]: \(facts.joined(separator: " · "))")
            }
        }

        return lines.joined(separator: "\n")
    }
}

public struct PerformanceThresholds: Codable, Equatable, Sendable {
    public var pingWarningMilliseconds: Int
    public var jitterWarningMilliseconds: Int
    public var packetLossWarningPercent: Double
    public var connectionReadyWarningMilliseconds: Int
    public var fullProbeWarningMilliseconds: Int

    public init(
        pingWarningMilliseconds: Int = 200,
        jitterWarningMilliseconds: Int = 60,
        packetLossWarningPercent: Double = 1,
        connectionReadyWarningMilliseconds: Int = 2_500,
        fullProbeWarningMilliseconds: Int = 5_000
    ) {
        self.pingWarningMilliseconds = pingWarningMilliseconds
        self.jitterWarningMilliseconds = jitterWarningMilliseconds
        self.packetLossWarningPercent = packetLossWarningPercent
        self.connectionReadyWarningMilliseconds = connectionReadyWarningMilliseconds
        self.fullProbeWarningMilliseconds = fullProbeWarningMilliseconds
    }

    public static let `default` = PerformanceThresholds()
}

public enum PerformanceWarningKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ping
    case jitter
    case packetLoss
    case connectionReady
    case fullProbe

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ping: "High ping"
        case .jitter: "High jitter"
        case .packetLoss: "Packet loss"
        case .connectionReady: "Slow SSH readiness"
        case .fullProbe: "Slow full probe"
        }
    }
}

public struct PerformanceWarning: Identifiable, Equatable, Sendable {
    public let kind: PerformanceWarningKind
    public let detail: String

    public var id: String { kind.rawValue }

    public init(kind: PerformanceWarningKind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}

public enum PerformanceEvaluator {
    public static func warnings(
        snapshot: HostSnapshot,
        thresholds: PerformanceThresholds
    ) -> [PerformanceWarning] {
        guard snapshot.state == .online else { return [] }
        var warnings: [PerformanceWarning] = []

        if let ping = snapshot.pingMilliseconds, ping >= thresholds.pingWarningMilliseconds {
            warnings.append(PerformanceWarning(
                kind: .ping,
                detail: "Ping is \(ping) ms; warning threshold is \(thresholds.pingWarningMilliseconds) ms."
            ))
        }
        if let jitter = snapshot.pingJitterMilliseconds, jitter >= thresholds.jitterWarningMilliseconds {
            warnings.append(PerformanceWarning(
                kind: .jitter,
                detail: "Jitter is \(jitter) ms; warning threshold is \(thresholds.jitterWarningMilliseconds) ms."
            ))
        }
        if let loss = snapshot.packetLossPercent, loss >= thresholds.packetLossWarningPercent {
            warnings.append(PerformanceWarning(
                kind: .packetLoss,
                detail: String(format: "Packet loss is %.1f%%; warning threshold is %.1f%%.", loss, thresholds.packetLossWarningPercent)
            ))
        }
        if let ready = snapshot.connectionReadyMilliseconds,
           ready >= thresholds.connectionReadyWarningMilliseconds {
            warnings.append(PerformanceWarning(
                kind: .connectionReady,
                detail: "SSH readiness is \(ready) ms; warning threshold is \(thresholds.connectionReadyWarningMilliseconds) ms."
            ))
        }
        if let probe = snapshot.probeDurationMilliseconds,
           probe >= thresholds.fullProbeWarningMilliseconds {
            warnings.append(PerformanceWarning(
                kind: .fullProbe,
                detail: "Full probe is \(probe) ms; warning threshold is \(thresholds.fullProbeWarningMilliseconds) ms."
            ))
        }
        return warnings
    }

    public static func healthPenalty(for warnings: [PerformanceWarning]) -> Int {
        min(30, warnings.reduce(0) { total, warning in
            total + (warning.kind == .packetLoss ? 10 : 5)
        })
    }
}

public enum PerformanceIncidentTransition: Equatable, Sendable {
    case none
    case attention
    case recovered
}

public struct PerformanceIncidentDecision: Equatable, Sendable {
    public let newConsecutiveCount: Int
    public let transition: PerformanceIncidentTransition

    public init(newConsecutiveCount: Int, transition: PerformanceIncidentTransition) {
        self.newConsecutiveCount = newConsecutiveCount
        self.transition = transition
    }
}

public enum PerformanceIncidentTracker {
    public static func evaluate(
        previousCount: Int,
        hasWarnings: Bool
    ) -> PerformanceIncidentDecision {
        if hasWarnings {
            let newCount = previousCount + 1
            return PerformanceIncidentDecision(
                newConsecutiveCount: newCount,
                transition: newCount == 2 ? .attention : .none
            )
        }
        return PerformanceIncidentDecision(
            newConsecutiveCount: 0,
            transition: previousCount >= 2 ? .recovered : .none
        )
    }
}

public enum FleetConnectionStatus: Equatable, Sendable {
    case pending
    case online
    case accessIssue
    case offline
}

public enum FleetConnectionClassifier {
    public static func status(for snapshot: HostSnapshot) -> FleetConnectionStatus {
        switch snapshot.state {
        case .checking, .waking:
            return .pending
        case .online:
            return .online
        case .unreachable:
            if snapshot.pingMilliseconds != nil,
               (snapshot.packetLossPercent ?? 0) < 100 {
                return .accessIssue
            }
            return .offline
        }
    }
}

public struct FleetAttentionSummary: Equatable, Sendable {
    public let onlineCount: Int
    public let unreachableCount: Int
    public let monitoringAccessIssueCount: Int
    public let performanceWarningCount: Int
    public let serviceOrResourceAlertCount: Int
    public let uniqueAttentionCount: Int

    public init(
        onlineCount: Int,
        unreachableCount: Int,
        monitoringAccessIssueCount: Int,
        performanceWarningCount: Int,
        serviceOrResourceAlertCount: Int,
        uniqueAttentionCount: Int
    ) {
        self.onlineCount = onlineCount
        self.unreachableCount = unreachableCount
        self.monitoringAccessIssueCount = monitoringAccessIssueCount
        self.performanceWarningCount = performanceWarningCount
        self.serviceOrResourceAlertCount = serviceOrResourceAlertCount
        self.uniqueAttentionCount = uniqueAttentionCount
    }

    public var compactDescription: String? {
        var parts: [String] = []
        if unreachableCount > 0 { parts.append("\(unreachableCount) offline") }
        if monitoringAccessIssueCount > 0 {
            parts.append("\(monitoringAccessIssueCount) access issue\(monitoringAccessIssueCount == 1 ? "" : "s")")
        }
        if performanceWarningCount > 0 { parts.append("\(performanceWarningCount) slow") }
        if serviceOrResourceAlertCount > 0 {
            parts.append("\(serviceOrResourceAlertCount) alert\(serviceOrResourceAlertCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public enum FleetStatusFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case online
    case offline
    case access
    case slow
    case alerts
    case attention

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All machines"
        case .online: "Online"
        case .offline: "Offline"
        case .access: "Access"
        case .slow: "Slow"
        case .alerts: "Alerts"
        case .attention: "All issues"
        }
    }
}

public enum FleetAttentionAnalyzer {
    public static func matches(
        snapshot: HostSnapshot,
        thresholds: PerformanceThresholds,
        filter: FleetStatusFilter
    ) -> Bool {
        let connectionStatus = FleetConnectionClassifier.status(for: snapshot)
        let isOffline = connectionStatus == .offline
        let hasAccessIssue = connectionStatus == .accessIssue
        let isSlow = snapshot.state == .online
            && !PerformanceEvaluator.warnings(snapshot: snapshot, thresholds: thresholds).isEmpty
        let hasAlert = snapshot.state == .online
            && ((snapshot.diskPercent ?? 0) >= 90
                || snapshot.services.contains(where: { $0.state.needsAttention }))

        return switch filter {
        case .all: true
        case .online: snapshot.state == .online
        case .offline: isOffline
        case .access: hasAccessIssue
        case .slow: isSlow
        case .alerts: hasAlert
        case .attention: isOffline || hasAccessIssue || isSlow || hasAlert
        }
    }

    public static func summarize(
        hosts: [FleetHost],
        snapshots: [String: HostSnapshot],
        thresholds: PerformanceThresholds
    ) -> FleetAttentionSummary {
        var onlineCount = 0
        var unreachableCount = 0
        var monitoringAccessIssueCount = 0
        var performanceWarningCount = 0
        var serviceOrResourceAlertCount = 0
        var attentionHostIDs: Set<String> = []

        for host in hosts {
            let snapshot = snapshots[host.id] ?? HostSnapshot()
            if snapshot.state == .online { onlineCount += 1 }

            let connectionStatus = FleetConnectionClassifier.status(for: snapshot)
            if connectionStatus == .offline {
                unreachableCount += 1
                attentionHostIDs.insert(host.id)
                continue
            }
            if connectionStatus == .accessIssue {
                monitoringAccessIssueCount += 1
                attentionHostIDs.insert(host.id)
                continue
            }

            if !PerformanceEvaluator.warnings(snapshot: snapshot, thresholds: thresholds).isEmpty {
                performanceWarningCount += 1
                attentionHostIDs.insert(host.id)
            }

            let hasServiceOrResourceAlert = (snapshot.diskPercent ?? 0) >= 90
                || snapshot.services.contains(where: { $0.state.needsAttention })
            if hasServiceOrResourceAlert {
                serviceOrResourceAlertCount += 1
                attentionHostIDs.insert(host.id)
            }
        }

        return FleetAttentionSummary(
            onlineCount: onlineCount,
            unreachableCount: unreachableCount,
            monitoringAccessIssueCount: monitoringAccessIssueCount,
            performanceWarningCount: performanceWarningCount,
            serviceOrResourceAlertCount: serviceOrResourceAlertCount,
            uniqueAttentionCount: attentionHostIDs.count
        )
    }
}

public enum FleetSortMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case priority
    case health
    case ping
    case name

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .priority: "Issues first"
        case .health: "Lowest health"
        case .ping: "Ping"
        case .name: "Name"
        }
    }

    public var systemImage: String {
        switch self {
        case .priority: "exclamationmark.triangle"
        case .health: "heart.text.square"
        case .ping: "arrow.left.and.right"
        case .name: "textformat.abc"
        }
    }
}

public enum FleetHostSorter {
    public static func sort(
        hosts: [FleetHost],
        snapshots: [String: HostSnapshot],
        thresholds: PerformanceThresholds,
        pinnedHostIDs: Set<String>,
        mode: FleetSortMode
    ) -> [FleetHost] {
        hosts.sorted { left, right in
            let leftPinned = pinnedHostIDs.contains(left.id)
            let rightPinned = pinnedHostIDs.contains(right.id)
            if leftPinned != rightPinned { return leftPinned }

            let leftSnapshot = snapshots[left.id] ?? HostSnapshot()
            let rightSnapshot = snapshots[right.id] ?? HostSnapshot()

            switch mode {
            case .priority:
                let leftSeverity = severity(of: leftSnapshot, thresholds: thresholds)
                let rightSeverity = severity(of: rightSnapshot, thresholds: thresholds)
                if leftSeverity != rightSeverity { return leftSeverity < rightSeverity }
            case .health:
                let leftHealth = HealthScorer.score(snapshot: leftSnapshot, availability: nil, thresholds: thresholds)
                let rightHealth = HealthScorer.score(snapshot: rightSnapshot, availability: nil, thresholds: thresholds)
                if leftHealth != rightHealth { return leftHealth < rightHealth }
            case .ping:
                let leftPing = leftSnapshot.state == .online ? leftSnapshot.pingMilliseconds : nil
                let rightPing = rightSnapshot.state == .online ? rightSnapshot.pingMilliseconds : nil
                switch (leftPing, rightPing) {
                case let (leftValue?, rightValue?) where leftValue != rightValue:
                    return leftValue < rightValue
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            case .name:
                break
            }

            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    private static func severity(
        of snapshot: HostSnapshot,
        thresholds: PerformanceThresholds
    ) -> Int {
        let connectionStatus = FleetConnectionClassifier.status(for: snapshot)
        if connectionStatus == .offline { return 0 }
        if connectionStatus == .accessIssue { return 1 }
        if snapshot.state == .online,
           (snapshot.diskPercent ?? 0) >= 90
            || snapshot.services.contains(where: { $0.state.needsAttention }) {
            return 2
        }
        if snapshot.state == .online,
           !PerformanceEvaluator.warnings(snapshot: snapshot, thresholds: thresholds).isEmpty {
            return 3
        }
        if snapshot.state == .checking || snapshot.state == .waking { return 4 }
        return 5
    }
}

public struct MetricSample: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let hostID: String
    public let state: HostState
    public let pingMilliseconds: Int?
    public let pingMinimumMilliseconds: Int?
    public let pingMaximumMilliseconds: Int?
    public let pingJitterMilliseconds: Int?
    public let packetLossPercent: Double?
    public let latencyMilliseconds: Int?
    public let probeDurationMilliseconds: Int?
    public let timingVersion: Int?
    public let diskPercent: Int?
    public let memoryPercent: Int?
    public let loadAverage: Double?
    public let routeName: String?
    public let serviceAttentionCount: Int
    public let detail: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        hostID: String,
        state: HostState,
        pingMilliseconds: Int? = nil,
        pingMinimumMilliseconds: Int? = nil,
        pingMaximumMilliseconds: Int? = nil,
        pingJitterMilliseconds: Int? = nil,
        packetLossPercent: Double? = nil,
        latencyMilliseconds: Int? = nil,
        probeDurationMilliseconds: Int? = nil,
        timingVersion: Int? = 2,
        diskPercent: Int? = nil,
        memoryPercent: Int? = nil,
        loadAverage: Double? = nil,
        routeName: String? = nil,
        serviceAttentionCount: Int = 0,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.hostID = hostID
        self.state = state
        self.pingMilliseconds = pingMilliseconds
        self.pingMinimumMilliseconds = pingMinimumMilliseconds
        self.pingMaximumMilliseconds = pingMaximumMilliseconds
        self.pingJitterMilliseconds = pingJitterMilliseconds
        self.packetLossPercent = packetLossPercent
        self.latencyMilliseconds = latencyMilliseconds
        self.probeDurationMilliseconds = probeDurationMilliseconds
        self.timingVersion = timingVersion
        self.diskPercent = diskPercent
        self.memoryPercent = memoryPercent
        self.loadAverage = loadAverage
        self.routeName = routeName
        self.serviceAttentionCount = serviceAttentionCount
        self.detail = detail
    }

    public init(hostID: String, snapshot: HostSnapshot, timestamp: Date = Date()) {
        self.init(
            timestamp: timestamp,
            hostID: hostID,
            state: snapshot.state,
            pingMilliseconds: snapshot.pingMilliseconds,
            pingMinimumMilliseconds: snapshot.pingMinimumMilliseconds,
            pingMaximumMilliseconds: snapshot.pingMaximumMilliseconds,
            pingJitterMilliseconds: snapshot.pingJitterMilliseconds,
            packetLossPercent: snapshot.packetLossPercent,
            latencyMilliseconds: snapshot.latencyMilliseconds,
            probeDurationMilliseconds: snapshot.probeDurationMilliseconds,
            timingVersion: 2,
            diskPercent: snapshot.diskPercent,
            memoryPercent: snapshot.memoryPercent,
            loadAverage: snapshot.loadAverage,
            routeName: snapshot.routeName,
            serviceAttentionCount: snapshot.services.filter { $0.state.needsAttention }.count,
            detail: snapshot.detail
        )
    }

    public var connectionReadyMilliseconds: Int? {
        timingVersion == 2 ? latencyMilliseconds : nil
    }

    public var effectiveProbeDurationMilliseconds: Int? {
        if let probeDurationMilliseconds { return probeDurationMilliseconds }
        return timingVersion == nil ? latencyMilliseconds : nil
    }

    public var probeWorkMilliseconds: Int? {
        guard let ready = connectionReadyMilliseconds,
              let total = effectiveProbeDurationMilliseconds,
              total >= ready else { return nil }
        return total - ready
    }
}

public enum FleetTimingMetric: String, CaseIterable, Identifiable, Sendable {
    case ping
    case connectionReady
    case checks
    case fullProbe

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ping: "Ping"
        case .connectionReady: "SSH ready"
        case .checks: "Checks"
        case .fullProbe: "Full probe"
        }
    }

    public func value(in snapshot: HostSnapshot) -> Int? {
        switch self {
        case .ping: snapshot.pingMilliseconds
        case .connectionReady: snapshot.connectionReadyMilliseconds
        case .checks: snapshot.probeWorkMilliseconds
        case .fullProbe: snapshot.probeDurationMilliseconds
        }
    }
}

public struct FleetTimingRank: Identifiable, Equatable, Sendable {
    public let host: FleetHost
    public let snapshot: HostSnapshot
    public let valueMilliseconds: Int?

    public var id: String { host.id }

    public init(host: FleetHost, snapshot: HostSnapshot, valueMilliseconds: Int?) {
        self.host = host
        self.snapshot = snapshot
        self.valueMilliseconds = valueMilliseconds
    }
}

public enum FleetTimingRanker {
    public static func rank(
        hosts: [FleetHost],
        snapshots: [String: HostSnapshot],
        metric: FleetTimingMetric
    ) -> [FleetTimingRank] {
        hosts.map { host in
            let snapshot = snapshots[host.id] ?? HostSnapshot()
            return FleetTimingRank(
                host: host,
                snapshot: snapshot,
                valueMilliseconds: host.isLocal ? nil : metric.value(in: snapshot)
            )
        }
        .sorted { left, right in
            let leftOnline = left.snapshot.state == .online
            let rightOnline = right.snapshot.state == .online
            if leftOnline != rightOnline { return leftOnline }

            switch (left.valueMilliseconds, right.valueMilliseconds) {
            case let (leftValue?, rightValue?):
                if leftValue != rightValue { return leftValue < rightValue }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            return left.host.displayName.localizedCaseInsensitiveCompare(right.host.displayName) == .orderedAscending
        }
    }
}

public enum FleetComparisonReportBuilder {
    public static func build(
        metric: FleetTimingMetric,
        ranks: [FleetTimingRank],
        generatedAt: Date = Date()
    ) -> String {
        var lines = [
            "Fleetlight comparison — \(metric.displayName) — \(generatedAt.formatted(date: .abbreviated, time: .standard))"
        ]
        let best = ranks.first(where: { $0.snapshot.state == .online && $0.valueMilliseconds != nil })?.valueMilliseconds

        for (index, rank) in ranks.enumerated() {
            let value = rank.valueMilliseconds.map { "\($0) ms" } ?? "unavailable"
            let delta = rank.valueMilliseconds.flatMap { value -> String? in
                guard rank.snapshot.state == .online, let best else { return nil }
                return value == best ? "fastest" : "+\(value - best) ms"
            }
            let route = rank.snapshot.routeName.map { "route \($0)" }
            let facts = [value, delta, route, rank.snapshot.state.rawValue].compactMap { $0 }.joined(separator: " · ")
            lines.append("\(index + 1). \(rank.host.displayName): \(facts)")
        }
        return lines.joined(separator: "\n")
    }
}

public struct CodexDesktopAppSummary: Sendable, Equatable {
    public let installedCount: Int
    public let offlineCount: Int
    public let missingCount: Int
    public let checkingCount: Int

    public init(installedCount: Int, offlineCount: Int, missingCount: Int, checkingCount: Int) {
        self.installedCount = installedCount
        self.offlineCount = offlineCount
        self.missingCount = missingCount
        self.checkingCount = checkingCount
    }
}

public struct CodexDesktopAppRelease: Sendable, Equatable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }
}

public enum CodexDesktopAppReleaseState: String, Sendable {
    case current
    case updateAvailable
    case offline
    case missing
    case unavailable
}

public struct CodexDesktopAppReleaseSummary: Sendable, Equatable {
    public let currentCount: Int
    public let updateAvailableCount: Int
    public let offlineCount: Int
    public let missingCount: Int
    public let unavailableCount: Int

    public init(
        currentCount: Int,
        updateAvailableCount: Int,
        offlineCount: Int,
        missingCount: Int,
        unavailableCount: Int
    ) {
        self.currentCount = currentCount
        self.updateAvailableCount = updateAvailableCount
        self.offlineCount = offlineCount
        self.missingCount = missingCount
        self.unavailableCount = unavailableCount
    }
}

public enum CodexDesktopAppReleaseChecker {
    public static func latestRelease(fromAppcastXML xml: String) -> CodexDesktopAppRelease? {
        guard let itemStart = xml.range(of: "<item>"),
              let itemEnd = xml.range(of: "</item>", range: itemStart.upperBound..<xml.endIndex) else {
            return nil
        }
        let item = String(xml[itemStart.upperBound..<itemEnd.lowerBound])
        guard let version = value(forTag: "sparkle:shortVersionString", in: item),
              let build = value(forTag: "sparkle:version", in: item),
              Int(build) != nil else {
            return nil
        }
        return CodexDesktopAppRelease(version: version, build: build)
    }

    public static func state(
        snapshot: HostSnapshot,
        latestRelease: CodexDesktopAppRelease?
    ) -> CodexDesktopAppReleaseState {
        if snapshot.state == .unreachable { return .offline }
        guard snapshot.state == .online else { return .unavailable }
        guard snapshot.codexDesktopAppVersion != nil else { return .missing }
        guard let installedBuild = snapshot.codexDesktopAppBuild.flatMap(Int.init),
              let latestBuild = latestRelease.flatMap({ Int($0.build) }) else {
            return .unavailable
        }
        return installedBuild < latestBuild ? .updateAvailable : .current
    }

    public static func summarize(
        hosts: [FleetHost],
        snapshots: [String: HostSnapshot],
        latestRelease: CodexDesktopAppRelease?
    ) -> CodexDesktopAppReleaseSummary {
        var current = 0
        var updates = 0
        var offline = 0
        var missing = 0
        var unavailable = 0

        for host in hosts where host.supportsCodexDesktopApp {
            switch state(snapshot: snapshots[host.id] ?? HostSnapshot(), latestRelease: latestRelease) {
            case .current: current += 1
            case .updateAvailable: updates += 1
            case .offline: offline += 1
            case .missing: missing += 1
            case .unavailable: unavailable += 1
            }
        }

        return CodexDesktopAppReleaseSummary(
            currentCount: current,
            updateAvailableCount: updates,
            offlineCount: offline,
            missingCount: missing,
            unavailableCount: unavailable
        )
    }

    private static func value(forTag tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        let value = xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum ReleaseCheckFreshness {
    public static func label(
        checkedAt: Date?,
        now: Date = Date(),
        failed: Bool
    ) -> String {
        guard let checkedAt else { return "Not checked yet" }
        let elapsed = max(0, now.timeIntervalSince(checkedAt))
        let age: String
        switch elapsed {
        case ..<60:
            age = "just now"
        case ..<3_600:
            age = "\(max(1, Int(elapsed / 60)))m ago"
        case ..<86_400:
            age = "\(max(1, Int(elapsed / 3_600)))h ago"
        default:
            age = "\(max(1, Int(elapsed / 86_400)))d ago"
        }
        return failed ? "Last attempt \(age)" : "Checked \(age)"
    }
}

public struct CodexUpdateAlert: Sendable, Equatable {
    public let releaseKey: String
    public let title: String
    public let body: String
    public let identifier: String

    public init(releaseKey: String, title: String, body: String, identifier: String) {
        self.releaseKey = releaseKey
        self.title = title
        self.body = body
        self.identifier = identifier
    }
}

public enum CodexUpdateAlertPlanner {
    public static func cliAlert(
        latestVersion: String?,
        updateCount: Int,
        lastNotifiedVersion: String?
    ) -> CodexUpdateAlert? {
        guard updateCount > 0,
              let latestVersion,
              latestVersion != lastNotifiedVersion else { return nil }
        let machines = updateCount == 1 ? "1 machine" : "\(updateCount) machines"
        return CodexUpdateAlert(
            releaseKey: latestVersion,
            title: "Codex CLI update available",
            body: "Version \(latestVersion) is available for \(machines).",
            identifier: "codex-cli-update-\(latestVersion)"
        )
    }

    public static func desktopAppAlert(
        latestRelease: CodexDesktopAppRelease?,
        updateCount: Int,
        lastNotifiedBuild: String?
    ) -> CodexUpdateAlert? {
        guard updateCount > 0,
              let latestRelease,
              latestRelease.build != lastNotifiedBuild else { return nil }
        let macs = updateCount == 1 ? "1 Mac" : "\(updateCount) Macs"
        return CodexUpdateAlert(
            releaseKey: latestRelease.build,
            title: "Codex Mac app update available",
            body: "Version \(latestRelease.version) (build \(latestRelease.build)) is available for \(macs).",
            identifier: "codex-mac-app-update-\(latestRelease.build)"
        )
    }
}

public struct CodexUpdateCenterSummary: Sendable, Equatable {
    public let cliUpdateCount: Int
    public let desktopAppUpdateCount: Int

    public init(cliUpdateCount: Int, desktopAppUpdateCount: Int) {
        self.cliUpdateCount = max(0, cliUpdateCount)
        self.desktopAppUpdateCount = max(0, desktopAppUpdateCount)
    }

    public var totalUpdateCount: Int {
        cliUpdateCount + desktopAppUpdateCount
    }

    public var detail: String {
        guard totalUpdateCount > 0 else { return "No updates available" }
        var parts: [String] = []
        if cliUpdateCount > 0 {
            parts.append("\(cliUpdateCount) CLI")
        }
        if desktopAppUpdateCount > 0 {
            parts.append("\(desktopAppUpdateCount) Mac app")
        }
        return parts.joined(separator: " · ")
    }

    public var confirmationTitle: String {
        let noun = totalUpdateCount == 1 ? "update" : "updates"
        return "Run \(totalUpdateCount) Codex \(noun)?"
    }

    public var confirmationDetail: String {
        var phases: [String] = []
        if cliUpdateCount > 0 {
            phases.append("\(cliUpdateCount) CLI update\(cliUpdateCount == 1 ? "" : "s")")
        }
        if desktopAppUpdateCount > 0 {
            phases.append("\(desktopAppUpdateCount) Mac app update\(desktopAppUpdateCount == 1 ? "" : "s")")
        }
        return phases.isEmpty
            ? "There are no available updates to run."
            : "Fleetlight will run " + phases.joined(separator: ", then ") + "."
    }
}

public enum CodexDesktopAppReportBuilder {
    public static func summarize(
        hosts: [FleetHost],
        snapshots: [String: HostSnapshot]
    ) -> CodexDesktopAppSummary {
        var installed = 0
        var offline = 0
        var missing = 0
        var checking = 0

        for host in hosts where host.supportsCodexDesktopApp {
            let snapshot = snapshots[host.id] ?? HostSnapshot()
            switch snapshot.state {
            case .online:
                if snapshot.codexDesktopAppVersion == nil {
                    missing += 1
                } else {
                    installed += 1
                }
            case .unreachable:
                offline += 1
            case .checking, .waking:
                checking += 1
            }
        }

        return CodexDesktopAppSummary(
            installedCount: installed,
            offlineCount: offline,
            missingCount: missing,
            checkingCount: checking
        )
    }

    public static func build(
        hosts: [FleetHost],
        snapshots: [String: HostSnapshot],
        latestRelease: CodexDesktopAppRelease? = nil,
        generatedAt: Date = Date()
    ) -> String {
        let appHosts = hosts.filter(\.supportsCodexDesktopApp)
        let summary = summarize(hosts: appHosts, snapshots: snapshots)
        var lines = [
            "Fleetlight Codex Mac app report — \(generatedAt.formatted(date: .abbreviated, time: .standard))",
            "Configured \(appHosts.count) · Installed \(summary.installedCount) · Offline \(summary.offlineCount) · Missing \(summary.missingCount) · Checking \(summary.checkingCount)"
        ]
        if let latestRelease {
            let releaseSummary = CodexDesktopAppReleaseChecker.summarize(
                hosts: appHosts,
                snapshots: snapshots,
                latestRelease: latestRelease
            )
            lines.append("Latest \(latestRelease.version) (build \(latestRelease.build)) · Current \(releaseSummary.currentCount) · Updates \(releaseSummary.updateAvailableCount)")
        }

        for host in appHosts {
            let snapshot = snapshots[host.id] ?? HostSnapshot()
            var facts: [String]
            switch snapshot.state {
            case .checking:
                facts = ["Checking"]
            case .waking:
                facts = ["Waking"]
            case .unreachable:
                facts = ["Offline"]
            case .online:
                if let version = snapshot.codexDesktopAppVersion {
                    let build = snapshot.codexDesktopAppBuild.map { " (build \($0))" } ?? ""
                    facts = ["Installed \(version)\(build)"]
                } else {
                    facts = ["Not installed"]
                }
            }
            if let checkedAt = snapshot.checkedAt {
                facts.append("checked \(checkedAt.formatted(date: .abbreviated, time: .standard))")
            }
            if CodexDesktopAppReleaseChecker.state(snapshot: snapshot, latestRelease: latestRelease) == .updateAvailable {
                facts.append("update available")
            }
            if let route = snapshot.routeName {
                facts.append("route \(route)")
            }
            lines.append("• \(host.displayName): \(facts.joined(separator: " · "))")
        }

        return lines.joined(separator: "\n")
    }
}

public enum HistoryAnalyzer {
    public static func recentSamples(
        _ samples: [MetricSample],
        hours: Double,
        now: Date = Date()
    ) -> [MetricSample] {
        let cutoff = now.addingTimeInterval(-hours * 3_600)
        return samples.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
    }

    public static func availabilityPercent(samples: [MetricSample]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let online = samples.filter { $0.state == .online }.count
        return Double(online) * 100 / Double(samples.count)
    }

    public static func averageConnectionReadyMilliseconds(samples: [MetricSample]) -> Double? {
        let values = samples.compactMap { sample -> Int? in
            guard sample.state == .online else { return nil }
            return sample.connectionReadyMilliseconds
        }
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    public static func averagePingMilliseconds(samples: [MetricSample]) -> Double? {
        let values = samples.compactMap(\.pingMilliseconds)
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    public static func averagePingJitterMilliseconds(samples: [MetricSample]) -> Double? {
        let values = samples.compactMap(\.pingJitterMilliseconds)
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    public static func averagePacketLossPercent(samples: [MetricSample]) -> Double? {
        let values = samples.compactMap(\.packetLossPercent)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func averageProbeDurationMilliseconds(samples: [MetricSample]) -> Double? {
        let values = samples.compactMap { sample -> Int? in
            guard sample.state == .online else { return nil }
            return sample.effectiveProbeDurationMilliseconds
        }
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    public static func averageProbeWorkMilliseconds(samples: [MetricSample]) -> Double? {
        let values = samples.compactMap { sample -> Int? in
            guard sample.state == .online else { return nil }
            return sample.probeWorkMilliseconds
        }
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    public static func incidentCount(samples: [MetricSample]) -> Int {
        guard let first = samples.first else { return 0 }
        var incidents = 0
        var previousWasHealthy = first.state == .online && first.serviceAttentionCount == 0

        for sample in samples.dropFirst() {
            let isHealthy = sample.state == .online && sample.serviceAttentionCount == 0
            if previousWasHealthy && !isHealthy { incidents += 1 }
            previousWasHealthy = isHealthy
        }
        return incidents
    }
}

public enum IncidentKind: String, Codable, Sendable {
    case hostDown
    case hostRecovered
    case serviceAttention
    case serviceRecovered
    case diskWarning
    case routeChanged
    case wakeVerified
    case wakeUnverified
    case performanceAttention
    case performanceRecovered

    public var displayName: String {
        switch self {
        case .hostDown: "Host unreachable"
        case .hostRecovered: "Host recovered"
        case .serviceAttention: "Service needs attention"
        case .serviceRecovered: "Service recovered"
        case .diskWarning: "Disk warning"
        case .routeChanged: "Route changed"
        case .wakeVerified: "Wake verified"
        case .wakeUnverified: "Wake unverified"
        case .performanceAttention: "Performance warning"
        case .performanceRecovered: "Performance recovered"
        }
    }

    public var systemImage: String {
        switch self {
        case .hostDown: "wifi.slash"
        case .hostRecovered: "checkmark.circle"
        case .serviceAttention: "exclamationmark.triangle"
        case .serviceRecovered: "wrench.and.screwdriver"
        case .diskWarning: "externaldrive.badge.exclamationmark"
        case .routeChanged: "arrow.triangle.branch"
        case .wakeVerified: "power.circle"
        case .wakeUnverified: "power.dotted"
        case .performanceAttention: "gauge.with.dots.needle.67percent"
        case .performanceRecovered: "gauge.with.dots.needle.0percent"
        }
    }

    public var category: IncidentCategory {
        switch self {
        case .hostDown, .hostRecovered, .wakeVerified, .wakeUnverified: .availability
        case .serviceAttention, .serviceRecovered: .services
        case .performanceAttention, .performanceRecovered: .performance
        case .diskWarning, .routeChanged: .system
        }
    }
}

public enum IncidentCategory: String, CaseIterable, Identifiable, Sendable {
    case availability
    case services
    case performance
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .availability: "Availability"
        case .services: "Services"
        case .performance: "Performance"
        case .system: "System"
        }
    }
}

public struct IncidentEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let hostID: String
    public let kind: IncidentKind
    public let title: String
    public let detail: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        hostID: String,
        kind: IncidentKind,
        title: String,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.hostID = hostID
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public struct ActiveIncidentState: Equatable, Sendable {
    private var eventsByKey: [String: IncidentEvent] = [:]

    public init(events: [IncidentEvent] = []) {
        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            apply(event)
        }
    }

    public var activeEvents: [IncidentEvent] {
        eventsByKey.values.sorted { $0.timestamp > $1.timestamp }
    }

    public var hostDownHostIDs: Set<String> {
        Set(eventsByKey.keys.compactMap { key in
            key.hasPrefix("availability:") ? String(key.dropFirst("availability:".count)) : nil
        })
    }

    public var performanceWarningHostIDs: Set<String> {
        Set(eventsByKey.keys.compactMap { key in
            key.hasPrefix("performance:") ? String(key.dropFirst("performance:".count)) : nil
        })
    }

    public mutating func apply(_ event: IncidentEvent) {
        guard let action = Self.action(for: event) else { return }
        if action.opens {
            eventsByKey[action.key] = event
        } else {
            eventsByKey.removeValue(forKey: action.key)
        }
    }

    private static func action(for event: IncidentEvent) -> (key: String, opens: Bool)? {
        switch event.kind {
        case .hostDown:
            ("availability:\(event.hostID)", true)
        case .hostRecovered:
            ("availability:\(event.hostID)", false)
        case .performanceAttention:
            ("performance:\(event.hostID)", true)
        case .performanceRecovered:
            ("performance:\(event.hostID)", false)
        case .serviceAttention:
            ("service:\(event.hostID):\(serviceName(from: event.title))", true)
        case .serviceRecovered:
            ("service:\(event.hostID):\(serviceName(from: event.title))", false)
        case .diskWarning, .routeChanged, .wakeVerified, .wakeUnverified:
            nil
        }
    }

    private static func serviceName(from title: String) -> String {
        for suffix in [" needs attention", " recovered"] where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count)).lowercased()
        }
        return title.lowercased()
    }
}

public enum RouteProbeState: String, Sendable {
    case checking
    case reachable
    case unreachable
}

public struct RouteProbeResult: Identifiable, Equatable, Sendable {
    public let route: SSHRoute
    public let state: RouteProbeState
    public let latencyMilliseconds: Int?
    public let detail: String
    public let checkedAt: Date?

    public var id: String { route.alias }

    public init(
        route: SSHRoute,
        state: RouteProbeState,
        latencyMilliseconds: Int? = nil,
        detail: String,
        checkedAt: Date? = nil
    ) {
        self.route = route
        self.state = state
        self.latencyMilliseconds = latencyMilliseconds
        self.detail = detail
        self.checkedAt = checkedAt
    }
}

public enum HealthScorer {
    public static func score(
        snapshot: HostSnapshot,
        availability: Double?,
        thresholds: PerformanceThresholds = .default
    ) -> Int {
        if FleetConnectionClassifier.status(for: snapshot) == .accessIssue { return 15 }
        guard snapshot.state == .online else { return 0 }
        var score = Int((availability ?? 100).rounded())

        if let disk = snapshot.diskPercent {
            if disk >= 90 { score -= 15 }
            else if disk >= 80 { score -= 5 }
        }
        if let memory = snapshot.memoryPercent {
            if memory >= 90 { score -= 10 }
            else if memory >= 80 { score -= 4 }
        }

        score -= min(45, snapshot.services.filter { $0.state.needsAttention }.count * 15)
        score -= PerformanceEvaluator.healthPenalty(
            for: PerformanceEvaluator.warnings(snapshot: snapshot, thresholds: thresholds)
        )
        if let route = snapshot.routeName, route.hasPrefix("Via ") || route == "Local network" {
            score -= 5
        }
        return min(100, max(0, score))
    }
}

public enum HistoryCSVBuilder {
    public static func build(samples: [MetricSample]) -> String {
        var rows = ["timestamp,host,state,ping_ms,ping_min_ms,ping_max_ms,jitter_ms,packet_loss_percent,connection_ready_ms,probe_duration_ms,check_work_ms,disk_percent,memory_percent,load,route,service_alerts,detail"]
        let formatter = ISO8601DateFormatter()

        for sample in samples.sorted(by: { $0.timestamp < $1.timestamp }) {
            let connectionReady = sample.connectionReadyMilliseconds.map(String.init) ?? ""
            let ping = sample.pingMilliseconds.map(String.init) ?? ""
            let pingMinimum = sample.pingMinimumMilliseconds.map(String.init) ?? ""
            let pingMaximum = sample.pingMaximumMilliseconds.map(String.init) ?? ""
            let jitter = sample.pingJitterMilliseconds.map(String.init) ?? ""
            let packetLoss = sample.packetLossPercent.map { String(format: "%.1f", $0) } ?? ""
            let probeDuration = sample.effectiveProbeDurationMilliseconds.map(String.init) ?? ""
            let checkWork = sample.probeWorkMilliseconds.map(String.init) ?? ""
            let disk = sample.diskPercent.map(String.init) ?? ""
            let memory = sample.memoryPercent.map(String.init) ?? ""
            let load = sample.loadAverage.map { String(format: "%.2f", $0) } ?? ""
            let fields: [String] = [
                formatter.string(from: sample.timestamp),
                sample.hostID,
                sample.state.rawValue,
                ping,
                pingMinimum,
                pingMaximum,
                jitter,
                packetLoss,
                connectionReady,
                probeDuration,
                checkWork,
                disk,
                memory,
                load,
                sample.routeName ?? "",
                String(sample.serviceAttentionCount),
                sample.detail ?? "",
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let elapsedMilliseconds: Int
    public let firstOutputMilliseconds: Int?
    public let timedOut: Bool

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        elapsedMilliseconds: Int,
        firstOutputMilliseconds: Int? = nil,
        timedOut: Bool
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.elapsedMilliseconds = elapsedMilliseconds
        self.firstOutputMilliseconds = firstOutputMilliseconds
        self.timedOut = timedOut
    }
}

public struct PingMeasurement: Equatable, Sendable {
    public let minimumMilliseconds: Int?
    public let averageMilliseconds: Int?
    public let maximumMilliseconds: Int?
    public let jitterMilliseconds: Int?
    public let packetLossPercent: Double?

    public init(
        minimumMilliseconds: Int? = nil,
        averageMilliseconds: Int? = nil,
        maximumMilliseconds: Int? = nil,
        jitterMilliseconds: Int? = nil,
        packetLossPercent: Double? = nil
    ) {
        self.minimumMilliseconds = minimumMilliseconds
        self.averageMilliseconds = averageMilliseconds
        self.maximumMilliseconds = maximumMilliseconds
        self.jitterMilliseconds = jitterMilliseconds
        self.packetLossPercent = packetLossPercent
    }
}

public enum PingParser {
    public static func measurement(from output: String) -> PingMeasurement? {
        let summary = output
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first(where: { $0.contains("min/avg/max") })

        var minimum: Int?
        var average: Int?
        var maximum: Int?
        var jitter: Int?
        if let summary, let equals = summary.firstIndex(of: "=") {
            let values = summary[summary.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "/")
                .compactMap { field -> Int? in
                    guard let numberText = field.split(whereSeparator: \Character.isWhitespace).first,
                          let number = Double(numberText),
                          number.isFinite,
                          number >= 0,
                          number <= 3_600_000 else { return nil }
                    return Int(number.rounded())
                }
            if values.count >= 4 {
                minimum = values[0]
                average = values[1]
                maximum = values[2]
                jitter = values[3]
            }
        }

        let parsedLoss = output
            .split(whereSeparator: \Character.isNewline)
            .first(where: { $0.contains("packet loss") })?
            .split(whereSeparator: \Character.isWhitespace)
            .first(where: { $0.hasSuffix("%") })
            .flatMap { Double($0.dropLast()) }
        let loss = parsedLoss.flatMap { value in
            value.isFinite && (0...100).contains(value) ? value : nil
        }

        guard average != nil || loss != nil else { return nil }
        return PingMeasurement(
            minimumMilliseconds: minimum,
            averageMilliseconds: average,
            maximumMilliseconds: maximum,
            jitterMilliseconds: jitter,
            packetLossPercent: loss
        )
    }

    public static func averageMilliseconds(from output: String) -> Int? {
        measurement(from: output)?.averageMilliseconds
    }
}

public enum NetworkDiagnosisLevel: String, Sendable {
    case healthy
    case notice
    case warning
}

public struct NetworkDiagnosis: Equatable, Sendable {
    public let level: NetworkDiagnosisLevel
    public let title: String
    public let detail: String

    public init(level: NetworkDiagnosisLevel, title: String, detail: String) {
        self.level = level
        self.title = title
        self.detail = detail
    }
}

public enum NetworkDiagnoser {
    public static func diagnose(snapshot: HostSnapshot) -> NetworkDiagnosis? {
        if snapshot.state == .unreachable, let ping = snapshot.pingMilliseconds {
            return sshFailureDiagnosis(detail: snapshot.detail, ping: ping)
        }

        if let loss = snapshot.packetLossPercent, loss > 0 {
            return NetworkDiagnosis(
                level: loss >= 10 ? .warning : .notice,
                title: "Packet loss detected",
                detail: String(format: "%.1f%% packet loss can cause retries, unstable sessions, and misleading timing spikes.", loss)
            )
        }

        if let jitter = snapshot.pingJitterMilliseconds, jitter >= 30 {
            return NetworkDiagnosis(
                level: jitter >= 60 ? .warning : .notice,
                title: "Network timing is unstable",
                detail: "Jitter is \(jitter) ms. The route is varying significantly between packets."
            )
        }

        if let ping = snapshot.pingMilliseconds, ping >= 150 {
            return NetworkDiagnosis(
                level: .notice,
                title: "Network round trip is elevated",
                detail: "Ping is \(ping) ms, so the network path is contributing materially to the total."
            )
        }

        if let ping = snapshot.pingMilliseconds,
           let ready = snapshot.connectionReadyMilliseconds,
           let checks = snapshot.probeWorkMilliseconds {
            return NetworkDiagnosis(
                level: .healthy,
                title: "Network path looks healthy",
                detail: "Ping is \(ping) ms; the remaining time is SSH setup (\(ready) ms) and remote checks (\(checks) ms)."
            )
        }

        return nil
    }

    private static func sshFailureDiagnosis(detail: String, ping: Int) -> NetworkDiagnosis {
        let message = detail.lowercased()
        let answered = "The host answered ping in \(ping) ms"

        if contains(message, any: ["host key verification failed", "remote host identification has changed"]) {
            return NetworkDiagnosis(
                level: .warning,
                title: "SSH host identity blocked",
                detail: "\(answered), but SSH rejected its saved identity. Verify the fingerprint before updating this observer’s known_hosts entry."
            )
        }
        if contains(message, any: ["permission denied", "publickey", "authentication failed", "too many authentication failures"]) {
            return NetworkDiagnosis(
                level: .warning,
                title: "SSH authentication rejected",
                detail: "\(answered), but non-interactive authentication was rejected. Diagnose in Terminal and verify this observer’s SSH key or agent."
            )
        }
        if contains(message, any: ["could not resolve hostname", "name or service not known", "nodename nor servname"]) {
            return NetworkDiagnosis(
                level: .warning,
                title: "SSH name could not be resolved",
                detail: "\(answered), but the SSH alias did not resolve correctly. Check its HostName entry in this observer’s ~/.ssh/config."
            )
        }
        if message.contains("connection refused") {
            return NetworkDiagnosis(
                level: .warning,
                title: "SSH service refused connection",
                detail: "\(answered), but the configured SSH port refused the connection. Verify sshd, the port, and the target firewall."
            )
        }
        if contains(message, any: ["connection timed out", "operation timed out", "ssh timed out", "timed out after"]) {
            return NetworkDiagnosis(
                level: .warning,
                title: "SSH connection timed out",
                detail: "\(answered), but the SSH handshake timed out. Check the route, firewall, VPN policy, and any jump host."
            )
        }
        if contains(message, any: ["connection closed", "connection reset", "kex_exchange_identification", "port 65535"]) {
            return NetworkDiagnosis(
                level: .warning,
                title: "SSH connection closed early",
                detail: "\(answered), but SSH was closed before Fleetlight’s verification marker. Check proxy, jump-host, VPN SSH policy, and server logs."
            )
        }
        if contains(message, any: ["no route to host", "network is unreachable"]) {
            return NetworkDiagnosis(
                level: .warning,
                title: "SSH route unavailable",
                detail: "\(answered), but SSH used a route that is unavailable from this observer. Check the SSH alias and recovery routes."
            )
        }
        return NetworkDiagnosis(
            level: .warning,
            title: "Network reachable, SSH failed",
            detail: "\(answered), but SSH monitoring did not complete. Diagnose in Terminal to inspect the interactive error."
        )
    }

    private static func contains(_ message: String, any patterns: [String]) -> Bool {
        patterns.contains { message.contains($0) }
    }
}

public enum SSHConfigParser {
    public static func hostname(from output: String) -> String? {
        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
            if fields.count == 2, fields[0].lowercased() == "hostname" {
                let hostname = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                return hostname.isEmpty ? nil : hostname
            }
        }
        return nil
    }
}

public enum ProbeParser {
    public static func snapshot(
        from result: CommandResult,
        route: SSHRoute? = nil,
        checkedAt: Date = Date()
    ) -> HostSnapshot {
        guard result.exitCode == 0, !result.timedOut else {
            return HostSnapshot(
                state: .unreachable,
                checkedAt: checkedAt,
                latencyMilliseconds: result.firstOutputMilliseconds,
                probeDurationMilliseconds: result.elapsedMilliseconds,
                routeName: route?.displayName,
                routeAlias: route?.alias,
                detail: failureDetail(from: result)
            )
        }

        let lines = result.stdout
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)

        guard lines.first == "FLEETLIGHT_OK" else {
            return HostSnapshot(
                state: .unreachable,
                checkedAt: checkedAt,
                latencyMilliseconds: result.firstOutputMilliseconds,
                probeDurationMilliseconds: result.elapsedMilliseconds,
                routeName: route?.displayName,
                routeAlias: route?.alias,
                detail: "SSH answered without the Fleetlight verification marker"
            )
        }

        let os = value(after: "OS=", in: lines)
        let boot = value(after: "BOOT=", in: lines)
        let codexVersion = preferredCodexVersion(values(after: "CODEX=", in: lines))
        let codexDesktopAppVersion = value(after: "CODEX_APP_VERSION=", in: lines)
        let codexDesktopAppBuild = value(after: "CODEX_APP_BUILD=", in: lines)
        let diskText = value(after: "DISK=", in: lines)?.replacingOccurrences(of: "%", with: "")
        let disk = diskText.flatMap(Int.init)
        let memory = value(after: "MEM=", in: lines).flatMap(Int.init)
        let load = value(after: "LOAD=", in: lines).flatMap(Double.init)
        let services = lines.compactMap(parseService)
        let diskDetail = disk.map { "Root disk \($0)% used" } ?? "Disk usage unavailable"

        return HostSnapshot(
            state: .online,
            checkedAt: checkedAt,
            latencyMilliseconds: result.firstOutputMilliseconds ?? result.elapsedMilliseconds,
            probeDurationMilliseconds: result.elapsedMilliseconds,
            operatingSystem: os,
            bootDescription: normalizeBoot(boot),
            codexVersion: codexVersion,
            codexDesktopAppVersion: codexDesktopAppVersion,
            codexDesktopAppBuild: codexDesktopAppBuild,
            diskPercent: disk,
            memoryPercent: memory,
            loadAverage: load,
            routeName: route?.displayName,
            routeAlias: route?.alias,
            services: services,
            detail: diskDetail
        )
    }

    private static func value(after prefix: String, in lines: [String]) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func values(after prefix: String, in lines: [String]) -> [String] {
        lines.compactMap { line in
            guard line.hasPrefix(prefix) else { return nil }
            let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private static func parseService(_ line: String) -> ServiceSnapshot? {
        guard line.hasPrefix("SERVICE=") else { return nil }
        let fields = line.dropFirst("SERVICE=".count).split(separator: "|", maxSplits: 2).map(String.init)
        guard fields.count == 3,
              let kind = ServiceKind(rawValue: fields[0]),
              let state = ServiceState(rawValue: fields[1]) else { return nil }
        return ServiceSnapshot(kind: kind, state: state, detail: fields[2])
    }

    private static func failureDetail(from result: CommandResult) -> String {
        if result.timedOut {
            return "Timed out after \(max(1, result.elapsedMilliseconds / 1_000)) seconds"
        }

        let meaningful = result.stderr
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })

        guard let meaningful else { return "SSH exited with code \(result.exitCode)" }
        return String(meaningful.prefix(120))
    }

    private static func normalizeCodexVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "not-installed": return "Not installed"
        case "unavailable": return "Unavailable"
        default:
            for prefix in ["codex-cli ", "codex "] where raw.lowercased().hasPrefix(prefix) {
                return String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return raw
        }
    }

    private static func preferredCodexVersion(_ rawValues: [String]) -> String? {
        let normalized = rawValues.compactMap(normalizeCodexVersion)
        let installed = normalized.filter { codexVersionComponents($0) != nil }

        if let newest = installed.max(by: isOlderCodexVersion) {
            return newest
        }
        if normalized.contains("Unavailable") { return "Unavailable" }
        if normalized.contains("Not installed") { return "Not installed" }
        return normalized.first
    }

    private static func codexVersionComponents(_ value: String) -> [Int]? {
        let core = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let components = parts.compactMap { Int($0) }
        return components.count == parts.count ? components : nil
    }

    private static func isOlderCodexVersion(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = codexVersionComponents(lhs),
              let right = codexVersionComponents(rhs) else { return false }
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart < rightPart }
        }
        return false
    }

    private static func normalizeBoot(_ raw: String?) -> String? {
        guard let raw else { return nil }

        if let range = raw.range(of: #"sec = ([0-9]+)"#, options: .regularExpression) {
            let match = raw[range]
            if let seconds = match.split(separator: "=").last?.trimmingCharacters(in: .whitespaces),
               let epoch = TimeInterval(seconds) {
                return Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened)
            }
        }

        return raw
    }
}

public enum RemoteCommandBuilder {
    public static func build(services: [ServiceKind]) -> String {
        let base = """
        printf 'FLEETLIGHT_OK\n'
        os=$(uname -s)
        if [ "$os" = Darwin ]; then
          boot=$(sysctl -n kern.boottime 2>/dev/null)
          load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/,""); print $1}')
          mem=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/{gsub(/%/,"",$2); printf "%.0f",100-$2}')
        else
          boot=$(uptime -s 2>/dev/null || true)
          load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
          mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2} END{if(t>0)printf "%.0f",(t-a)*100/t}' /proc/meminfo 2>/dev/null)
        fi
        disk=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $5}')
        codex_candidates=$(
          command -v codex 2>/dev/null || true
          for candidate in "$HOME/.local/bin/codex" "$HOME/.npm-global/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
            if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; fi
          done
          if [ -d "$HOME/.nvm/versions/node" ]; then
            find "$HOME/.nvm/versions/node" -type f -path '*/bin/codex' 2>/dev/null
          fi
        )
        codex_versions=$(
          printf '%s\n' "$codex_candidates" | awk 'NF && !seen[$0]++' | while IFS= read -r codex_bin; do
            codex_version=$("$codex_bin" -V 2>/dev/null | sed -n '1p' | tr -d '\r')
            if [ -n "$codex_version" ]; then printf 'CODEX=%s\n' "$codex_version"; else printf 'CODEX=unavailable\n'; fi
          done
        )
        if [ -n "$codex_versions" ]; then printf '%s\n' "$codex_versions"; else printf 'CODEX=not-installed\n'; fi
        if [ "$os" = Darwin ]; then
          codex_app_plist=/Applications/ChatGPT.app/Contents/Info.plist
          if [ -r "$codex_app_plist" ]; then
            codex_app_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$codex_app_plist" 2>/dev/null)
            if [ "$codex_app_id" = com.openai.codex ]; then
              codex_app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$codex_app_plist" 2>/dev/null)
              codex_app_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$codex_app_plist" 2>/dev/null)
              printf 'CODEX_APP_VERSION=%s\nCODEX_APP_BUILD=%s\n' "$codex_app_version" "$codex_app_build"
            fi
          fi
        fi
        printf 'OS=%s\nBOOT=%s\nDISK=%s\nLOAD=%s\nMEM=%s\n' "$os" "$boot" "$disk" "$load" "$mem"
        """

        return ([base] + services.map(serviceCommand)).joined(separator: "\n")
    }

    private static func serviceCommand(_ service: ServiceKind) -> String {
        switch service {
        case .tailscale:
            return """
            if command -v tailscale >/dev/null 2>&1; then
              if tailscale status --json >/dev/null 2>&1; then printf 'SERVICE=tailscale|healthy|Connected\n'; else printf 'SERVICE=tailscale|stopped|Backend unavailable\n'; fi
            else printf 'SERVICE=tailscale|unavailable|CLI missing\n'; fi
            """
        case .docker:
            return """
            if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then printf 'SERVICE=docker|healthy|Daemon active\n'
            elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then printf 'SERVICE=docker|healthy|Daemon responding\n'
            elif command -v docker >/dev/null 2>&1; then printf 'SERVICE=docker|stopped|Daemon unavailable\n'
            else printf 'SERVICE=docker|unavailable|Docker missing\n'; fi
            """
        case .plex:
            return """
            if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet plexmediaserver 2>/dev/null; then printf 'SERVICE=plex|healthy|Server active\n'
            elif pgrep -f 'Plex Media Server' >/dev/null 2>&1; then printf 'SERVICE=plex|healthy|Process running\n'
            else printf 'SERVICE=plex|stopped|Server inactive\n'; fi
            """
        case .samba:
            return """
            if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet smbd 2>/dev/null; then printf 'SERVICE=samba|healthy|File sharing active\n'
            else printf 'SERVICE=samba|stopped|File sharing inactive\n'; fi
            """
        }
    }
}

public enum CodexReleaseChecker {
    private struct ParsedVersion {
        let core: [Int]
        let prerelease: [String]?
    }

    public static func latestVersion(fromRegistryJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let rawVersion = dictionary["version"] as? String else { return nil }
        return normalizedDisplayVersion(rawVersion)
    }

    public static func isUpdateAvailable(installedVersion: String?, latestVersion: String?) -> Bool {
        guard let installedVersion,
              let latestVersion,
              let installed = parse(installedVersion),
              let latest = parse(latestVersion) else { return false }
        return compare(installed, latest) < 0
    }

    public static func isComparableVersion(_ version: String?) -> Bool {
        guard let version else { return false }
        return parse(version) != nil
    }

    private static func normalizedDisplayVersion(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = value.lowercased()
        for prefix in ["codex-cli ", "codex "] where lowered.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if value.lowercased().hasPrefix("v"), value.dropFirst().first?.isNumber == true {
            value.removeFirst()
        }
        return parse(value) == nil ? nil : value
    }

    private static func parse(_ raw: String) -> ParsedVersion? {
        guard let normalized = normalizedForParsing(raw) else { return nil }
        let withoutBuild = normalized.split(separator: "+", maxSplits: 1).first.map(String.init) ?? normalized
        let sections = withoutBuild.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let coreParts = sections[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !coreParts.isEmpty else { return nil }
        let core = coreParts.compactMap { Int($0) }
        guard core.count == coreParts.count else { return nil }

        var prerelease: [String]?
        if sections.count == 2 {
            let identifiers = sections[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
            prerelease = identifiers
        }
        return ParsedVersion(core: core, prerelease: prerelease)
    }

    private static func normalizedForParsing(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = value.lowercased()
        for prefix in ["codex-cli ", "codex "] where lowered.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if value.lowercased().hasPrefix("v"), value.dropFirst().first?.isNumber == true {
            value.removeFirst()
        }
        return value.isEmpty ? nil : value
    }

    private static func compare(_ lhs: ParsedVersion, _ rhs: ParsedVersion) -> Int {
        for index in 0..<max(lhs.core.count, rhs.core.count) {
            let left = index < lhs.core.count ? lhs.core[index] : 0
            let right = index < rhs.core.count ? rhs.core[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return 0
        case (nil, _?):
            return 1
        case (_?, nil):
            return -1
        case let (left?, right?):
            for index in 0..<min(left.count, right.count) {
                let leftIdentifier = left[index]
                let rightIdentifier = right[index]
                if leftIdentifier == rightIdentifier { continue }
                switch (Int(leftIdentifier), Int(rightIdentifier)) {
                case let (leftNumber?, rightNumber?):
                    return leftNumber < rightNumber ? -1 : 1
                case (_?, nil):
                    return -1
                case (nil, _?):
                    return 1
                case (nil, nil):
                    return leftIdentifier < rightIdentifier ? -1 : 1
                }
            }
            if left.count == right.count { return 0 }
            return left.count < right.count ? -1 : 1
        }
    }
}

public struct LinuxPackageUpdate: Codable, Equatable, Sendable {
    public let name: String
    public let installedVersion: String?
    public let availableVersion: String?

    public init(name: String, installedVersion: String? = nil, availableVersion: String? = nil) {
        self.name = name
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
    }

    public var versionTransition: String {
        switch (installedVersion, availableVersion) {
        case let (installed?, available?): "\(installed) → \(available)"
        case let (nil, available?): "available \(available)"
        case let (installed?, nil): "installed \(installed)"
        case (nil, nil): "version unavailable"
        }
    }
}

public enum LinuxUpdateState: String, Codable, Sendable {
    case notChecked
    case checking
    case current
    case updateAvailable
    case offline
    case unsupported
    case failed
}

public struct LinuxUpdateSnapshot: Codable, Equatable, Sendable {
    public let state: LinuxUpdateState
    public let distribution: String?
    public let kernelVersion: String?
    public let packageManager: String?
    public let packageUpdateCount: Int
    public let securityUpdateCount: Int
    public let snapUpdateCount: Int
    public let flatpakUpdateCount: Int
    public let availablePackages: [LinuxPackageUpdate]
    public let rebootRequired: Bool
    public let checkedAt: Date?
    public let detail: String

    public var totalUpdateCount: Int {
        packageUpdateCount + snapUpdateCount + flatpakUpdateCount
    }

    public init(
        state: LinuxUpdateState = .notChecked,
        distribution: String? = nil,
        kernelVersion: String? = nil,
        packageManager: String? = nil,
        packageUpdateCount: Int = 0,
        securityUpdateCount: Int = 0,
        snapUpdateCount: Int = 0,
        flatpakUpdateCount: Int = 0,
        availablePackages: [LinuxPackageUpdate] = [],
        rebootRequired: Bool = false,
        checkedAt: Date? = nil,
        detail: String = "Updates have not been checked"
    ) {
        self.state = state
        self.distribution = distribution
        self.kernelVersion = kernelVersion
        self.packageManager = packageManager
        self.packageUpdateCount = packageUpdateCount
        self.securityUpdateCount = securityUpdateCount
        self.snapUpdateCount = snapUpdateCount
        self.flatpakUpdateCount = flatpakUpdateCount
        self.availablePackages = availablePackages
        self.rebootRequired = rebootRequired
        self.checkedAt = checkedAt
        self.detail = detail
    }
}

public struct LinuxUpdateSummary: Equatable, Sendable {
    public let currentCount: Int
    public let updateAvailableCount: Int
    public let offlineCount: Int
    public let unavailableCount: Int
    public let totalPendingUpdates: Int

    public init(currentCount: Int, updateAvailableCount: Int, offlineCount: Int, unavailableCount: Int, totalPendingUpdates: Int) {
        self.currentCount = currentCount
        self.updateAvailableCount = updateAvailableCount
        self.offlineCount = offlineCount
        self.unavailableCount = unavailableCount
        self.totalPendingUpdates = totalPendingUpdates
    }
}

public enum LinuxUpdateAnalyzer {
    public static func summarize(hosts: [FleetHost], snapshots: [String: LinuxUpdateSnapshot]) -> LinuxUpdateSummary {
        var currentCount = 0
        var updateAvailableCount = 0
        var offlineCount = 0
        var unavailableCount = 0
        var totalPendingUpdates = 0

        for host in hosts {
            let snapshot = snapshots[host.id] ?? LinuxUpdateSnapshot()
            totalPendingUpdates += snapshot.totalUpdateCount
            switch snapshot.state {
            case .current: currentCount += 1
            case .updateAvailable: updateAvailableCount += 1
            case .offline: offlineCount += 1
            case .notChecked, .checking, .unsupported, .failed: unavailableCount += 1
            }
        }

        return LinuxUpdateSummary(
            currentCount: currentCount,
            updateAvailableCount: updateAvailableCount,
            offlineCount: offlineCount,
            unavailableCount: unavailableCount,
            totalPendingUpdates: totalPendingUpdates
        )
    }

    public static func availableHosts(hosts: [FleetHost], snapshots: [String: LinuxUpdateSnapshot]) -> [FleetHost] {
        hosts.filter { snapshots[$0.id]?.state == .updateAvailable }
    }

    public static func restartRequiredHosts(hosts: [FleetHost], snapshots: [String: LinuxUpdateSnapshot]) -> [FleetHost] {
        hosts.filter { snapshots[$0.id]?.rebootRequired == true }
    }
}


public enum LinuxUpdateCheckCommandBuilder {
    public static func build() -> String {
        """
        printf 'FLEETLIGHT_LINUX_UPDATE_CHECK\n'
        if [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
          printf 'STATUS:not-linux\n'
          exit 3
        fi

        distribution=$(awk -F= '/^PRETTY_NAME=/{value=$2; gsub(/^"|"$/,"",value); print value; exit}' /etc/os-release 2>/dev/null)
        [ -n "$distribution" ] || distribution=$(uname -s)
        printf 'DISTRIBUTION:%s\nKERNEL:%s\n' "$distribution" "$(uname -r 2>/dev/null)"

        if [ "$(id -u)" -eq 0 ]; then
          run_privileged() { "$@"; }
        elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
          run_privileged() { sudo -n "$@"; }
        else
          printf 'STATUS:privilege-required\n'
          exit 4
        fi

        package_file=$(mktemp /tmp/fleetlight-linux-packages.XXXXXX)
        metadata_log=$(mktemp /tmp/fleetlight-linux-metadata.XXXXXX)
        cleanup_linux_check() { rm -f "$package_file" "$package_file.clean" "$metadata_log"; }
        trap cleanup_linux_check EXIT
        package_manager=
        package_count=0
        security_count=0

        if command -v apt-get >/dev/null 2>&1; then
          package_manager=apt
          if ! run_privileged apt-get update >"$metadata_log" 2>&1; then
            printf 'PKG_MGR:%s\nSTATUS:metadata-failed\nERROR:%s\n' "$package_manager" "$(tail -n 1 "$metadata_log" | tr -d '\r')"
            exit 5
          fi
          apt list --upgradable 2>/dev/null | tail -n +2 >"$package_file"
          package_count=$(grep -c . "$package_file" 2>/dev/null || true)
          security_count=$(grep -c -- '-security' "$package_file" 2>/dev/null || true)
          head -n 12 "$package_file" | while IFS= read -r line; do
            [ -n "$line" ] || continue
            name=$(printf '%s\n' "$line" | cut -d/ -f1)
            available=$(printf '%s\n' "$line" | awk '{print $2}')
            installed=$(printf '%s\n' "$line" | sed -n 's/.*upgradable from: \\([^]]*\\).*/\\1/p')
            printf 'PACKAGE:%s|%s|%s\n' "$name" "$installed" "$available"
          done
        elif command -v dnf >/dev/null 2>&1; then
          package_manager=dnf
          if ! run_privileged dnf -q makecache --refresh >"$metadata_log" 2>&1; then
            printf 'PKG_MGR:%s\nSTATUS:metadata-failed\nERROR:%s\n' "$package_manager" "$(tail -n 1 "$metadata_log" | tr -d '\r')"
            exit 5
          fi
          dnf -q check-update >"$package_file" 2>/dev/null
          check_status=$?
          if [ "$check_status" -ne 0 ] && [ "$check_status" -ne 100 ]; then
            printf 'PKG_MGR:%s\nSTATUS:check-failed\n' "$package_manager"
            exit 5
          fi
          awk 'NF >= 3 && $1 !~ /^(Last|Obsoleting)/ {print}' "$package_file" >"$package_file.clean"
          mv "$package_file.clean" "$package_file"
          package_count=$(grep -c . "$package_file" 2>/dev/null || true)
          head -n 12 "$package_file" | awk '{printf "PACKAGE:%s||%s\n",$1,$3}'
        elif command -v yum >/dev/null 2>&1; then
          package_manager=yum
          run_privileged yum -q makecache >"$metadata_log" 2>&1 || true
          yum -q check-update >"$package_file" 2>/dev/null
          check_status=$?
          if [ "$check_status" -ne 0 ] && [ "$check_status" -ne 100 ]; then
            printf 'PKG_MGR:%s\nSTATUS:check-failed\n' "$package_manager"
            exit 5
          fi
          awk 'NF >= 3 && $1 !~ /^(Loaded|Loading|Last|Obsoleting)/ {print}' "$package_file" >"$package_file.clean"
          mv "$package_file.clean" "$package_file"
          package_count=$(grep -c . "$package_file" 2>/dev/null || true)
          head -n 12 "$package_file" | awk '{printf "PACKAGE:%s||%s\n",$1,$2}'
        elif command -v pacman >/dev/null 2>&1; then
          package_manager=pacman
          if command -v checkupdates >/dev/null 2>&1; then
            checkupdates >"$package_file" 2>/dev/null || true
          else
            pacman -Qu >"$package_file" 2>/dev/null || true
          fi
          package_count=$(grep -c . "$package_file" 2>/dev/null || true)
          head -n 12 "$package_file" | awk '{printf "PACKAGE:%s|%s|%s\n",$1,$2,$4}'
        elif command -v zypper >/dev/null 2>&1; then
          package_manager=zypper
          if ! run_privileged zypper --non-interactive refresh >"$metadata_log" 2>&1; then
            printf 'PKG_MGR:%s\nSTATUS:metadata-failed\nERROR:%s\n' "$package_manager" "$(tail -n 1 "$metadata_log" | tr -d '\r')"
            exit 5
          fi
          zypper --non-interactive --no-refresh list-updates >"$package_file" 2>/dev/null || true
          awk -F'|' '$1 ~ /v/ {for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i)}; printf "PACKAGE:%s|%s|%s\n",$3,$4,$5}' "$package_file" >"$package_file.clean"
          mv "$package_file.clean" "$package_file"
          package_count=$(grep -c . "$package_file" 2>/dev/null || true)
          head -n 12 "$package_file"
        elif command -v apk >/dev/null 2>&1; then
          package_manager=apk
          if ! run_privileged apk update >"$metadata_log" 2>&1; then
            printf 'PKG_MGR:%s\nSTATUS:metadata-failed\nERROR:%s\n' "$package_manager" "$(tail -n 1 "$metadata_log" | tr -d '\r')"
            exit 5
          fi
          apk version -l '<' >"$package_file" 2>/dev/null || true
          package_count=$(grep -c . "$package_file" 2>/dev/null || true)
          head -n 12 "$package_file" | awk '{printf "PACKAGE:%s||%s\n",$1,$3}'
        else
          printf 'STATUS:unsupported-package-manager\n'
          exit 6
        fi

        printf 'PKG_MGR:%s\nPACKAGE_COUNT:%s\nSECURITY_COUNT:%s\n' "$package_manager" "$package_count" "$security_count"

        snap_count=0
        if command -v snap >/dev/null 2>&1; then
          snap refresh --list >"$package_file" 2>/dev/null || true
          if ! grep -qi 'All snaps up to date' "$package_file"; then
            snap_count=$(tail -n +2 "$package_file" | grep -c . 2>/dev/null || true)
          fi
        fi
        printf 'SNAP_COUNT:%s\n' "$snap_count"

        flatpak_count=0
        if command -v flatpak >/dev/null 2>&1; then
          flatpak_user_count=$(flatpak remote-ls --updates --user --columns=application 2>/dev/null | grep -c . || true)
          flatpak_system_count=$(flatpak remote-ls --updates --system --columns=application 2>/dev/null | grep -c . || true)
          flatpak_count=$((flatpak_user_count + flatpak_system_count))
        fi
        printf 'FLATPAK_COUNT:%s\n' "$flatpak_count"
        if [ -f /var/run/reboot-required ]; then printf 'REBOOT:required\n'; else printf 'REBOOT:not-required\n'; fi
        printf 'STATUS:ok\n'
        """
    }
}

public enum LinuxUpdateCheckParser {
    public static func snapshot(from result: CommandResult, checkedAt: Date = Date()) -> LinuxUpdateSnapshot {
        let lines = normalizedLines(result.stdout)
        let distribution = value(after: "DISTRIBUTION:", in: lines)
        let kernel = value(after: "KERNEL:", in: lines)
        let packageManager = value(after: "PKG_MGR:", in: lines)

        if result.timedOut {
            return LinuxUpdateSnapshot(state: .failed, distribution: distribution, kernelVersion: kernel, packageManager: packageManager, checkedAt: checkedAt, detail: "Update check timed out")
        }
        if isOfflineFailure(result) {
            return LinuxUpdateSnapshot(state: .offline, checkedAt: checkedAt, detail: offlineDetail(result))
        }
        if lines.contains("STATUS:not-linux") {
            return LinuxUpdateSnapshot(state: .unsupported, distribution: distribution, kernelVersion: kernel, checkedAt: checkedAt, detail: "Machine is not running Linux")
        }
        if lines.contains("STATUS:privilege-required") {
            return LinuxUpdateSnapshot(state: .failed, distribution: distribution, kernelVersion: kernel, packageManager: packageManager, checkedAt: checkedAt, detail: "Passwordless sudo is required")
        }
        guard result.exitCode == 0, lines.first == "FLEETLIGHT_LINUX_UPDATE_CHECK", lines.contains("STATUS:ok") else {
            let error = value(after: "ERROR:", in: lines) ?? value(after: "STATUS:", in: lines) ?? "Update check failed"
            return LinuxUpdateSnapshot(state: .failed, distribution: distribution, kernelVersion: kernel, packageManager: packageManager, checkedAt: checkedAt, detail: error.replacingOccurrences(of: "-", with: " ").capitalized)
        }

        let packageCount = value(after: "PACKAGE_COUNT:", in: lines).flatMap(Int.init) ?? 0
        let securityCount = value(after: "SECURITY_COUNT:", in: lines).flatMap(Int.init) ?? 0
        let snapCount = value(after: "SNAP_COUNT:", in: lines).flatMap(Int.init) ?? 0
        let flatpakCount = value(after: "FLATPAK_COUNT:", in: lines).flatMap(Int.init) ?? 0
        let packages = lines.compactMap(parsePackage)
        let rebootRequired = lines.contains("REBOOT:required")
        let total = packageCount + snapCount + flatpakCount
        let detail = total == 0 ? "System packages are current" : "\(total) update\(total == 1 ? "" : "s") available"

        return LinuxUpdateSnapshot(
            state: total > 0 ? .updateAvailable : .current,
            distribution: distribution,
            kernelVersion: kernel,
            packageManager: packageManager,
            packageUpdateCount: packageCount,
            securityUpdateCount: securityCount,
            snapUpdateCount: snapCount,
            flatpakUpdateCount: flatpakCount,
            availablePackages: packages,
            rebootRequired: rebootRequired,
            checkedAt: checkedAt,
            detail: detail
        )
    }

    private static func parsePackage(_ line: String) -> LinuxPackageUpdate? {
        guard line.hasPrefix("PACKAGE:") else { return nil }
        let fields = line.dropFirst("PACKAGE:".count).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, !fields[0].isEmpty else { return nil }
        return LinuxPackageUpdate(name: fields[0], installedVersion: fields[1].isEmpty ? nil : fields[1], availableVersion: fields[2].isEmpty ? nil : fields[2])
    }

    private static func normalizedLines(_ output: String) -> [String] {
        output.split(whereSeparator: \Character.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func value(after prefix: String, in lines: [String]) -> String? {
        guard let line = lines.last(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isOfflineFailure(_ result: CommandResult) -> Bool {
        if result.exitCode == 255 { return true }
        let message = (result.stderr + "\n" + result.stdout).lowercased()
        return message.contains("no ssh route configured")
            || message.contains("connection refused")
            || message.contains("connection timed out")
            || message.contains("operation timed out")
            || message.contains("no route to host")
            || message.contains("could not resolve hostname")
            || message.contains("network is unreachable")
    }

    private static func offlineDetail(_ result: CommandResult) -> String {
        let detail = result.stderr.split(whereSeparator: \Character.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.last(where: { !$0.isEmpty })
        return detail.map { String($0.prefix(120)) } ?? "Machine is offline"
    }
}


public enum LinuxUpdateStatus: Equatable, Sendable {
    case succeeded
    case offline
    case failed
}

public struct LinuxUpdateOutcome: Equatable, Sendable {
    public let status: LinuxUpdateStatus
    public let rebootRequired: Bool
    public let detail: String

    public init(status: LinuxUpdateStatus, rebootRequired: Bool, detail: String) {
        self.status = status
        self.rebootRequired = rebootRequired
        self.detail = detail
    }
}

public enum LinuxUpdateCommandBuilder {
    public static func build() -> String {
        """
        printf 'FLEETLIGHT_LINUX_UPDATE\n'
        if [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
          printf 'UPDATE:not-linux\n'
          exit 3
        fi

        if [ "$(id -u)" -eq 0 ]; then
          run_privileged() { "$@"; }
        elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
          run_privileged() { sudo -n "$@"; }
        else
          printf 'UPDATE:privilege-required\n'
          exit 4
        fi

        update_log=$(mktemp /tmp/fleetlight-linux-update.XXXXXX)
        cleanup_linux_update() { rm -f "$update_log"; }
        trap cleanup_linux_update EXIT
        status=0

        if command -v apt-get >/dev/null 2>&1; then
          package_manager=apt
          run_privileged apt-get update >"$update_log" 2>&1 \
            && run_privileged env DEBIAN_FRONTEND=noninteractive apt-get -y -o APT::Get::Always-Include-Phased-Updates=true full-upgrade >>"$update_log" 2>&1 \
            && run_privileged apt-get -y autoremove >>"$update_log" 2>&1 || status=1
        elif command -v dnf >/dev/null 2>&1; then
          package_manager=dnf
          run_privileged dnf -y upgrade --refresh >"$update_log" 2>&1 || status=1
        elif command -v yum >/dev/null 2>&1; then
          package_manager=yum
          run_privileged yum -y update >"$update_log" 2>&1 || status=1
        elif command -v pacman >/dev/null 2>&1; then
          package_manager=pacman
          run_privileged pacman -Syu --noconfirm >"$update_log" 2>&1 || status=1
        elif command -v zypper >/dev/null 2>&1; then
          package_manager=zypper
          run_privileged zypper --non-interactive refresh >"$update_log" 2>&1 \
            && run_privileged zypper --non-interactive update >>"$update_log" 2>&1 || status=1
        elif command -v apk >/dev/null 2>&1; then
          package_manager=apk
          run_privileged apk update >"$update_log" 2>&1 \
            && run_privileged apk upgrade >>"$update_log" 2>&1 || status=1
        else
          printf 'UPDATE:unsupported-package-manager\n'
          exit 5
        fi
        printf 'PKG_MGR:%s\n' "$package_manager"

        if command -v snap >/dev/null 2>&1; then
          snap_ok=0
          snap_attempt=1
          while [ "$snap_attempt" -le 3 ]; do
            if run_privileged snap refresh >>"$update_log" 2>&1; then snap_ok=1; break; fi
            [ "$snap_attempt" -ge 3 ] || sleep $((snap_attempt * 5))
            snap_attempt=$((snap_attempt + 1))
          done
          [ "$snap_ok" -eq 1 ] || status=1
        fi

        if command -v flatpak >/dev/null 2>&1; then
          flatpak_user_ok=0
          flatpak_attempt=1
          while [ "$flatpak_attempt" -le 3 ]; do
            if flatpak update -y --noninteractive --user >>"$update_log" 2>&1; then flatpak_user_ok=1; break; fi
            [ "$flatpak_attempt" -ge 3 ] || sleep $((flatpak_attempt * 5))
            flatpak_attempt=$((flatpak_attempt + 1))
          done
          [ "$flatpak_user_ok" -eq 1 ] || status=1

          flatpak_system_ok=0
          flatpak_attempt=1
          while [ "$flatpak_attempt" -le 3 ]; do
            if run_privileged flatpak update -y --noninteractive --system >>"$update_log" 2>&1; then flatpak_system_ok=1; break; fi
            [ "$flatpak_attempt" -ge 3 ] || sleep $((flatpak_attempt * 5))
            flatpak_attempt=$((flatpak_attempt + 1))
          done
          [ "$flatpak_system_ok" -eq 1 ] || status=1
        fi

        if [ -f /var/run/reboot-required ]; then printf 'REBOOT:required\n'; else printf 'REBOOT:not-required\n'; fi
        if [ "$status" -eq 0 ]; then printf 'UPDATE:ok\n'; exit 0; fi
        tail -n 20 "$update_log" 2>/dev/null || true
        printf 'UPDATE:failed\n'
        exit 1
        """
    }
}

public enum LinuxUpdateParser {
    public static func outcome(from result: CommandResult) -> LinuxUpdateOutcome {
        let lines = result.stdout.split(whereSeparator: \Character.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let rebootRequired = lines.contains("REBOOT:required")

        if result.timedOut {
            return LinuxUpdateOutcome(status: .failed, rebootRequired: rebootRequired, detail: "Linux update timed out")
        }
        if result.exitCode == 255 || result.stderr.lowercased().contains("no route to host") {
            return LinuxUpdateOutcome(status: .offline, rebootRequired: rebootRequired, detail: "Machine went offline")
        }
        if lines.contains("UPDATE:privilege-required") {
            return LinuxUpdateOutcome(status: .failed, rebootRequired: rebootRequired, detail: "Passwordless sudo is required")
        }
        if result.exitCode == 0, lines.contains("UPDATE:ok") {
            return LinuxUpdateOutcome(status: .succeeded, rebootRequired: rebootRequired, detail: rebootRequired ? "Update completed · restart required" : "Update completed")
        }
        if lines.contains("UPDATE:not-linux") {
            return LinuxUpdateOutcome(status: .failed, rebootRequired: rebootRequired, detail: "Machine is not running Linux")
        }
        if lines.contains("UPDATE:unsupported-package-manager") {
            return LinuxUpdateOutcome(status: .failed, rebootRequired: rebootRequired, detail: "Package manager is not supported")
        }
        return LinuxUpdateOutcome(status: .failed, rebootRequired: rebootRequired, detail: "Linux update failed")
    }
}


public enum LinuxRestartStatus: Equatable, Sendable {
    case scheduled
    case offline
    case failed
}

public struct LinuxRestartOutcome: Equatable, Sendable {
    public let status: LinuxRestartStatus
    public let bootDescriptionBeforeRestart: String?
    public let detail: String

    public init(status: LinuxRestartStatus, bootDescriptionBeforeRestart: String? = nil, detail: String) {
        self.status = status
        self.bootDescriptionBeforeRestart = bootDescriptionBeforeRestart
        self.detail = detail
    }
}

public enum LinuxRestartCommandBuilder {
    public static func build() -> String {
        """
        printf 'FLEETLIGHT_LINUX_RESTART\n'
        if [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
          printf 'RESTART:not-linux\n'
          exit 3
        fi

        if [ "$(id -u)" -eq 0 ]; then
          run_privileged() { "$@"; }
        elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
          run_privileged() { sudo -n "$@"; }
        else
          printf 'RESTART:privilege-required\n'
          exit 4
        fi

        boot_before=$(uptime -s 2>/dev/null || true)
        [ -n "$boot_before" ] || boot_before=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
        printf 'BOOT_BEFORE:%s\n' "$boot_before"

        restart_command="sleep 2; if command -v systemctl >/dev/null 2>&1 && systemctl reboot; then exit 0; fi; if command -v shutdown >/dev/null 2>&1; then shutdown -r now; else reboot; fi"
        if run_privileged /bin/sh -c "nohup /bin/sh -c '$restart_command' >/dev/null 2>&1 </dev/null &"; then
          printf 'RESTART:scheduled\n'
          exit 0
        fi

        printf 'RESTART:failed\n'
        exit 1
        """
    }
}

public enum LinuxRestartParser {
    public static func outcome(from result: CommandResult) -> LinuxRestartOutcome {
        let lines = result.stdout
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let bootBefore = value(after: "BOOT_BEFORE:", in: lines)

        if lines.first == "FLEETLIGHT_LINUX_RESTART", lines.contains("RESTART:scheduled") {
            return LinuxRestartOutcome(
                status: .scheduled,
                bootDescriptionBeforeRestart: bootBefore,
                detail: "Restart issued · waiting for the machine to return"
            )
        }
        if result.timedOut {
            return LinuxRestartOutcome(status: .failed, bootDescriptionBeforeRestart: bootBefore, detail: "Restart command timed out")
        }
        if result.exitCode == 255 || isOfflineMessage(result.stderr) {
            return LinuxRestartOutcome(status: .offline, bootDescriptionBeforeRestart: bootBefore, detail: "Machine is offline")
        }
        if lines.contains("RESTART:privilege-required") {
            return LinuxRestartOutcome(status: .failed, bootDescriptionBeforeRestart: bootBefore, detail: "Passwordless sudo is required")
        }
        if lines.contains("RESTART:not-linux") {
            return LinuxRestartOutcome(status: .failed, bootDescriptionBeforeRestart: bootBefore, detail: "Machine is not running Linux")
        }
        return LinuxRestartOutcome(status: .failed, bootDescriptionBeforeRestart: bootBefore, detail: "Restart command failed")
    }

    private static func value(after prefix: String, in lines: [String]) -> String? {
        guard let line = lines.last(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isOfflineMessage(_ message: String) -> Bool {
        let message = message.lowercased()
        return message.contains("connection refused")
            || message.contains("connection timed out")
            || message.contains("operation timed out")
            || message.contains("no route to host")
            || message.contains("could not resolve hostname")
            || message.contains("network is unreachable")
    }
}


public enum CodexUpdatePlanner {
    public static func availableHosts(
        hosts: [FleetHost],
        snapshots: [String: HostSnapshot],
        latestVersion: String?
    ) -> [FleetHost] {
        hosts.filter { host in
            let snapshot = snapshots[host.id]
            return snapshot?.state == .online
                && CodexReleaseChecker.isUpdateAvailable(
                    installedVersion: snapshot?.codexVersion,
                    latestVersion: latestVersion
                )
        }
    }
}

public enum CodexFleetVersionState: String, Sendable {
    case current
    case updateAvailable
    case offline
    case unavailable
}

public struct CodexFleetVersionSummary: Equatable, Sendable {
    public let currentCount: Int
    public let updateAvailableCount: Int
    public let offlineCount: Int
    public let unavailableCount: Int

    public init(
        currentCount: Int,
        updateAvailableCount: Int,
        offlineCount: Int,
        unavailableCount: Int
    ) {
        self.currentCount = currentCount
        self.updateAvailableCount = updateAvailableCount
        self.offlineCount = offlineCount
        self.unavailableCount = unavailableCount
    }
}

public enum CodexFleetVersionAnalyzer {
    public static func state(
        snapshot: HostSnapshot,
        latestVersion: String?
    ) -> CodexFleetVersionState {
        if snapshot.state == .unreachable {
            return .offline
        }
        guard snapshot.state == .online,
              CodexReleaseChecker.isComparableVersion(snapshot.codexVersion),
              CodexReleaseChecker.isComparableVersion(latestVersion) else {
            return .unavailable
        }
        return CodexReleaseChecker.isUpdateAvailable(
            installedVersion: snapshot.codexVersion,
            latestVersion: latestVersion
        ) ? .updateAvailable : .current
    }

    public static func summarize(
        hosts: [FleetHost],
        snapshots: [String: HostSnapshot],
        latestVersion: String?
    ) -> CodexFleetVersionSummary {
        var currentCount = 0
        var updateAvailableCount = 0
        var offlineCount = 0
        var unavailableCount = 0

        for host in hosts {
            switch state(
                snapshot: snapshots[host.id] ?? HostSnapshot(),
                latestVersion: latestVersion
            ) {
            case .current:
                currentCount += 1
            case .updateAvailable:
                updateAvailableCount += 1
            case .offline:
                offlineCount += 1
            case .unavailable:
                unavailableCount += 1
            }
        }

        return CodexFleetVersionSummary(
            currentCount: currentCount,
            updateAvailableCount: updateAvailableCount,
            offlineCount: offlineCount,
            unavailableCount: unavailableCount
        )
    }
}

public enum CodexUpdateRecoveryPlanner {
    public static func retryHostIDs(
        orderedHostIDs: [String],
        problemHostIDs: Set<String>,
        onlineHostIDs: Set<String>
    ) -> [String] {
        orderedHostIDs.filter { hostID in
            problemHostIDs.contains(hostID) && onlineHostIDs.contains(hostID)
        }
    }
}

public enum CodexUpdateStatus: Equatable, Sendable {
    case succeeded
    case offline
    case failed
}

public struct CodexUpdateOutcome: Equatable, Sendable {
    public let status: CodexUpdateStatus
    public let activeVersion: String?
    public let detail: String

    public var succeeded: Bool { status == .succeeded }

    public init(status: CodexUpdateStatus, activeVersion: String?, detail: String) {
        self.status = status
        self.activeVersion = activeVersion
        self.detail = detail
    }
}

public enum CodexUpdateCommandBuilder {
    public static func build() -> String {
        """
        printf 'FLEETLIGHT_CODEX_UPDATE\n'
        shell_bin=${SHELL:-/bin/sh}
        interactive_before=$("$shell_bin" -ic 'codex -V 2>/dev/null' 2>/dev/null)
        before_version=$(printf '%s\n' "$interactive_before" | sed -n 's/^codex-cli //p' | tail -n 1 | tr -d '\r')
        update_mode=interactive
        codex_bin=
        if [ -z "$before_version" ]; then
          update_mode=binary
          interactive_path=$("$shell_bin" -ic 'printf "FLEETLIGHT_PATH=%s\n" "$PATH"' 2>/dev/null | sed -n 's/^FLEETLIGHT_PATH=//p' | tail -n 1 | tr -d '\r')
          old_ifs=$IFS
          IFS=:
          for directory in $interactive_path; do
            if [ -n "$directory" ] && [ -x "$directory/codex" ]; then codex_bin="$directory/codex"; break; fi
          done
          IFS=$old_ifs
        fi
        if [ -z "$codex_bin" ]; then
          for candidate in "$HOME/.local/bin/codex" "$HOME/.npm-global/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex /usr/bin/codex; do
            if [ -x "$candidate" ]; then codex_bin=$candidate; break; fi
          done
        fi
        if [ -z "$codex_bin" ] && [ -d "$HOME/.nvm/versions/node" ]; then
          codex_bin=$(find "$HOME/.nvm/versions/node" -type f -path '*/bin/codex' 2>/dev/null | sed -n '1p')
        fi
        if [ "$update_mode" = binary ] && { [ -z "$codex_bin" ] || [ ! -x "$codex_bin" ]; }; then
          printf 'UPDATE:missing\nVERIFY:failed\n'
          exit 2
        fi

        if [ "$update_mode" = binary ]; then
          PATH=$(dirname "$codex_bin"):$PATH
          export PATH
          before_version=$("$codex_bin" -V 2>/dev/null | sed -n 's/^codex-cli //p' | tail -n 1 | tr -d '\r')
        fi
        printf 'BEFORE_VERSION:%s\n' "$before_version"
        update_log=$(mktemp "${TMPDIR:-/tmp}/fleetlight-codex-update.XXXXXX")
        if [ "$update_mode" = interactive ]; then
          "$shell_bin" -ic 'codex update' >"$update_log" 2>&1
        else
          "$codex_bin" update >"$update_log" 2>&1
        fi
        update_status=$?
        tail -n 12 "$update_log" 2>/dev/null || true
        rm -f "$update_log"

        interactive_after=$("$shell_bin" -ic 'codex -V 2>/dev/null' 2>/dev/null)
        active_version=$(printf '%s\n' "$interactive_after" | sed -n 's/^codex-cli //p' | tail -n 1 | tr -d '\r')
        if [ -z "$active_version" ] && [ -n "$codex_bin" ]; then
          active_version=$("$codex_bin" -V 2>/dev/null | sed -n 's/^codex-cli //p' | tail -n 1 | tr -d '\r')
        fi
        printf 'ACTIVE_VERSION:%s\n' "$active_version"
        if [ "$update_status" -eq 0 ] && [ -n "$active_version" ]; then
          printf 'UPDATE:ok\nVERIFY:ok\n'
          exit 0
        fi
        printf 'UPDATE:failed:%s\nVERIFY:failed\n' "$update_status"
        exit 1
        """
    }
}

public enum CodexUpdateParser {
    public static func outcome(from result: CommandResult) -> CodexUpdateOutcome {
        let lines = result.stdout
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let activeVersion = value(after: "ACTIVE_VERSION:", in: lines).flatMap(normalizeVersion)

        if result.timedOut {
            return CodexUpdateOutcome(
                status: .failed,
                activeVersion: activeVersion,
                detail: "Update timed out"
            )
        }

        if isOfflineFailure(result) {
            return CodexUpdateOutcome(
                status: .offline,
                activeVersion: activeVersion,
                detail: offlineDetail(for: result)
            )
        }

        if result.exitCode == 0, lines.contains("VERIFY:ok") {
            let detail = activeVersion.map { "Codex \($0) is current" } ?? "Codex update completed"
            return CodexUpdateOutcome(status: .succeeded, activeVersion: activeVersion, detail: detail)
        }

        if lines.contains("UPDATE:missing") {
            return CodexUpdateOutcome(
                status: .failed,
                activeVersion: nil,
                detail: "Codex is not installed"
            )
        }

        if let activeVersion {
            return CodexUpdateOutcome(
                status: .failed,
                activeVersion: activeVersion,
                detail: "Update failed; still using Codex \(activeVersion)"
            )
        }

        let errorLine = result.stderr
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
            ?? lines.last(where: { line in
                !line.hasPrefix("FLEETLIGHT_")
                    && !line.hasPrefix("BEFORE_VERSION:")
                    && !line.hasPrefix("UPDATE:")
                    && !line.hasPrefix("VERIFY:")
            })
        return CodexUpdateOutcome(
            status: .failed,
            activeVersion: nil,
            detail: errorLine.map { String($0.prefix(140)) } ?? "Codex update failed"
        )
    }

    private static func isOfflineFailure(_ result: CommandResult) -> Bool {
        if result.exitCode == 255 { return true }
        let message = (result.stderr + "\n" + result.stdout).lowercased()
        return message.contains("no ssh route configured")
            || message.contains("connection refused")
            || message.contains("connection timed out")
            || message.contains("operation timed out")
            || message.contains("no route to host")
            || message.contains("could not resolve hostname")
            || message.contains("network is unreachable")
            || message.contains("connection closed")
    }

    private static func offlineDetail(for result: CommandResult) -> String {
        let message = (result.stderr + "\n" + result.stdout).lowercased()
        if message.contains("no ssh route configured") { return "Offline — no SSH route configured" }
        if message.contains("could not resolve hostname") { return "Offline — SSH host was not found" }
        if message.contains("connection refused") { return "Offline — SSH connection was refused" }
        if message.contains("timed out") { return "Offline — SSH timed out" }
        if message.contains("no route to host") || message.contains("network is unreachable") {
            return "Offline — network route unavailable"
        }
        return "Offline — SSH connection unavailable"
    }

    private static func value(after prefix: String, in lines: [String]) -> String? {
        guard let line = lines.last(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func normalizeVersion(_ raw: String) -> String? {
        let value = raw.lowercased().hasPrefix("codex-cli ")
            ? String(raw.dropFirst("codex-cli ".count))
            : raw
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public enum CodexDesktopAppUpdateStatus: Equatable, Sendable {
    case current
    case updated
    case offline
    case failed
}

public struct CodexDesktopAppUpdateOutcome: Equatable, Sendable {
    public let status: CodexDesktopAppUpdateStatus
    public let activeVersion: String?
    public let activeBuild: String?
    public let detail: String

    public var succeeded: Bool { status == .current || status == .updated }

    public init(
        status: CodexDesktopAppUpdateStatus,
        activeVersion: String?,
        activeBuild: String?,
        detail: String
    ) {
        self.status = status
        self.activeVersion = activeVersion
        self.activeBuild = activeBuild
        self.detail = detail
    }
}

public enum CodexDesktopAppUpdateCommandBuilder {
    public static func build() -> String {
        """
        printf 'FLEETLIGHT_CODEX_APP_UPDATE\n'
        if [ "$(uname -s)" != Darwin ]; then
          printf 'UPDATE:unsupported\nVERIFY:failed\n'
          exit 2
        fi

        app=/Applications/ChatGPT.app
        plist="$app/Contents/Info.plist"
        if [ ! -r "$plist" ]; then
          printf 'UPDATE:missing\nVERIFY:failed\n'
          exit 2
        fi
        bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)
        if [ "$bundle_id" != com.openai.codex ]; then
          printf 'UPDATE:wrong-app\nVERIFY:failed\n'
          exit 2
        fi

        read_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null; }
        read_build() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null; }
        before_version=$(read_version)
        before_build=$(read_build)
        printf 'BEFORE_VERSION:%s\nBEFORE_BUILD:%s\n' "$before_version" "$before_build"

        if ! pgrep ChatGPT >/dev/null 2>&1; then
          /usr/bin/open -gj "$app" >/dev/null 2>&1 || true
          launch_attempt=0
          while ! pgrep ChatGPT >/dev/null 2>&1 && [ "$launch_attempt" -lt 20 ]; do
            sleep 1
            launch_attempt=$((launch_attempt + 1))
          done
        fi
        if ! pgrep ChatGPT >/dev/null 2>&1; then
          printf 'UPDATE:not-running\nVERIFY:failed\n'
          exit 3
        fi

        click_result=$(/usr/bin/osascript 2>&1 <<'APPLESCRIPT'
        tell application "System Events"
          if not (exists process "ChatGPT") then error "ChatGPT process is unavailable"
          tell process "ChatGPT"
            click menu item "Check for Updates…" of menu 1 of menu bar item "ChatGPT" of menu bar 1
          end tell
        end tell
        APPLESCRIPT
        )
        click_status=$?
        if [ "$click_status" -ne 0 ]; then
          printf 'ERROR:%s\nUPDATE:permission\nVERIFY:failed\n' "$(printf '%s' "$click_result" | tail -n 1 | tr '\n' ' ')"
          exit 3
        fi

        inspect_update_dialog() {
          /usr/bin/osascript 2>&1 <<'APPLESCRIPT'
        set updateButtonNames to {"Install and Relaunch", "Update and Relaunch", "Restart to Update", "Install Update", "Download and Install", "Update Now", "Relaunch", "Download", "Update"}
        tell application "System Events"
          if not (exists process "ChatGPT") then return "restarting"
          tell process "ChatGPT"
            repeat with updateWindow in windows
              set dialogText to ""
              try
                set dialogText to (value of every static text of updateWindow) as text
              end try
              ignoring case
                if dialogText contains "up to date" or dialogText contains "newest version available" then
                  try
                    click button "OK" of updateWindow
                  end try
                  return "current"
                end if
              end ignoring
              repeat with buttonName in updateButtonNames
                set candidateName to buttonName as text
                if exists button candidateName of updateWindow then
                  click button candidateName of updateWindow
                  return "acted:" & candidateName
                end if
              end repeat
            end repeat
          end tell
        end tell
        return "waiting"
        APPLESCRIPT
        }

        elapsed=0
        acted=0
        saw_restart=0
        while [ "$elapsed" -lt 360 ]; do
          after_version=$(read_version)
          after_build=$(read_build)
          if { [ "$after_version" != "$before_version" ] || [ "$after_build" != "$before_build" ]; } && pgrep ChatGPT >/dev/null 2>&1; then
            printf 'AFTER_VERSION:%s\nAFTER_BUILD:%s\nUPDATE:ok\nVERIFY:updated\n' "$after_version" "$after_build"
            exit 0
          fi

          if ! pgrep ChatGPT >/dev/null 2>&1; then
            saw_restart=1
            sleep 2
            elapsed=$((elapsed + 2))
            continue
          fi

          dialog_result=$(inspect_update_dialog)
          dialog_status=$?
          if [ "$dialog_status" -ne 0 ]; then
            printf 'ERROR:%s\nUPDATE:permission\nVERIFY:failed\n' "$(printf '%s' "$dialog_result" | tail -n 1 | tr '\n' ' ')"
            exit 3
          fi
          case "$dialog_result" in
            current)
              printf 'AFTER_VERSION:%s\nAFTER_BUILD:%s\nUPDATE:current\nVERIFY:current\n' "$after_version" "$after_build"
              exit 0
              ;;
            acted:*) acted=1 ;;
            restarting) saw_restart=1 ;;
          esac

          if [ "$saw_restart" -eq 1 ] && [ "$elapsed" -ge 45 ]; then
            /usr/bin/open -gj "$app" >/dev/null 2>&1 || true
          fi
          if [ "$acted" -eq 0 ] && [ "$elapsed" -ge 45 ]; then
            printf 'UPDATE:no-result\nVERIFY:failed\n'
            exit 4
          fi
          sleep 2
          elapsed=$((elapsed + 2))
        done

        after_version=$(read_version)
        after_build=$(read_build)
        printf 'AFTER_VERSION:%s\nAFTER_BUILD:%s\nUPDATE:timeout\nVERIFY:failed\n' "$after_version" "$after_build"
        exit 4
        """
    }
}

public enum CodexDesktopAppUpdateParser {
    public static func outcome(from result: CommandResult) -> CodexDesktopAppUpdateOutcome {
        let lines = result.stdout
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let activeVersion = value(after: "AFTER_VERSION:", in: lines)
            ?? value(after: "BEFORE_VERSION:", in: lines)
        let activeBuild = value(after: "AFTER_BUILD:", in: lines)
            ?? value(after: "BEFORE_BUILD:", in: lines)

        if result.timedOut {
            return outcome(.failed, activeVersion, activeBuild, "Codex app update timed out")
        }
        if isOfflineFailure(result) {
            return outcome(.offline, activeVersion, activeBuild, "Offline — SSH connection unavailable")
        }
        if lines.contains("VERIFY:updated") {
            return outcome(.updated, activeVersion, activeBuild, versionDetail(prefix: "Updated Codex app to", version: activeVersion, build: activeBuild))
        }
        if lines.contains("VERIFY:current") {
            return outcome(.current, activeVersion, activeBuild, versionDetail(prefix: "Codex app is current at", version: activeVersion, build: activeBuild))
        }
        if lines.contains("UPDATE:missing") {
            return outcome(.failed, nil, nil, "Codex desktop app is not installed")
        }
        if lines.contains("UPDATE:unsupported") {
            return outcome(.failed, nil, nil, "Codex desktop app updates require macOS")
        }
        if lines.contains("UPDATE:permission") {
            return outcome(.failed, activeVersion, activeBuild, "Allow Fleetlight to control System Events in macOS Privacy & Security")
        }
        if lines.contains("UPDATE:not-running") {
            return outcome(.failed, activeVersion, activeBuild, "Codex desktop app could not be opened")
        }

        let error = value(after: "ERROR:", in: lines)
        return outcome(.failed, activeVersion, activeBuild, error.map { String($0.prefix(160)) } ?? "Codex app update did not complete")
    }

    private static func outcome(
        _ status: CodexDesktopAppUpdateStatus,
        _ version: String?,
        _ build: String?,
        _ detail: String
    ) -> CodexDesktopAppUpdateOutcome {
        CodexDesktopAppUpdateOutcome(status: status, activeVersion: version, activeBuild: build, detail: detail)
    }

    private static func versionDetail(prefix: String, version: String?, build: String?) -> String {
        guard let version else { return prefix }
        return build.map { "\(prefix) \(version) (build \($0))" } ?? "\(prefix) \(version)"
    }

    private static func value(after prefix: String, in lines: [String]) -> String? {
        guard let line = lines.last(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isOfflineFailure(_ result: CommandResult) -> Bool {
        if result.exitCode == 255 { return true }
        let message = (result.stderr + "\n" + result.stdout).lowercased()
        return message.contains("no ssh route configured")
            || message.contains("connection refused")
            || message.contains("connection timed out")
            || message.contains("operation timed out")
            || message.contains("no route to host")
            || message.contains("could not resolve hostname")
            || message.contains("network is unreachable")
    }
}


public enum FleetReportBuilder {
    public static func build(
        hosts: [FleetHost],
        snapshots: [String: HostSnapshot],
        thresholds: PerformanceThresholds = .default,
        generatedAt: Date = Date(),
        observerName: String = FleetObserver.currentDisplayName,
        appVersion: String = FleetlightVersion.currentDisplayLabel
    ) -> String {
        var lines = [
            "Fleetlight full diagnosis — \(generatedAt.formatted(date: .abbreviated, time: .standard))",
            "Observer: \(observerName) · Fleetlight \(appVersion)",
        ]

        for host in hosts {
            let snapshot = snapshots[host.id] ?? HostSnapshot()
            let connectionLabel = switch FleetConnectionClassifier.status(for: snapshot) {
            case .pending: snapshot.state.rawValue.capitalized
            case .online: "Online"
            case .accessIssue: "Access issue"
            case .offline: "Offline"
            }
            var facts = [connectionLabel]
            if let os = snapshot.operatingSystem { facts.append(os) }
            if let codexVersion = snapshot.codexVersion { facts.append("Codex \(codexVersion)") }
            if let appVersion = snapshot.codexDesktopAppVersion {
                let build = snapshot.codexDesktopAppBuild.map { " (build \($0))" } ?? ""
                facts.append("Codex app \(appVersion)\(build)")
            }
            if let disk = snapshot.diskPercent { facts.append("disk \(disk)%") }
            if let memory = snapshot.memoryPercent { facts.append("memory \(memory)%") }
            if let load = snapshot.loadAverage { facts.append(String(format: "load %.2f", load)) }
            if let ping = snapshot.pingMilliseconds { facts.append("ping \(ping) ms") }
            if let minimum = snapshot.pingMinimumMilliseconds,
               let maximum = snapshot.pingMaximumMilliseconds {
                facts.append("ping range \(minimum)-\(maximum) ms")
            }
            if let jitter = snapshot.pingJitterMilliseconds { facts.append("jitter \(jitter) ms") }
            if let loss = snapshot.packetLossPercent { facts.append(String(format: "loss %.1f%%", loss)) }
            if let latency = snapshot.latencyMilliseconds { facts.append("ready \(latency) ms") }
            if let duration = snapshot.probeDurationMilliseconds { facts.append("probe \(duration) ms") }
            if let work = snapshot.probeWorkMilliseconds { facts.append("checks \(work) ms") }
            if let route = snapshot.routeName { facts.append("route \(route)") }
            if let boot = snapshot.bootDescription { facts.append("boot \(boot)") }
            lines.append("• \(host.displayName) [\(host.id)]: \(facts.joined(separator: " · ")) — \(snapshot.detail)")

            if let diagnosis = NetworkDiagnoser.diagnose(snapshot: snapshot) {
                lines.append("  - Network diagnosis: \(diagnosis.title) — \(diagnosis.detail)")
            }

            for warning in PerformanceEvaluator.warnings(snapshot: snapshot, thresholds: thresholds) {
                lines.append("  - Performance warning: \(warning.kind.displayName) — \(warning.detail)")
            }

            for service in snapshot.services {
                lines.append("  - \(service.kind.displayName): \(service.state.rawValue) — \(service.detail)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
