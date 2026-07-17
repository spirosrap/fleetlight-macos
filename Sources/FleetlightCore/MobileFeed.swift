import Foundation

public struct MobileFeedObserver: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let appVersion: String
    public let status: String
    public let lastRefreshDurationMilliseconds: Int?

    public init(
        id: String,
        name: String,
        appVersion: String,
        status: String = "reporting",
        lastRefreshDurationMilliseconds: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.appVersion = appVersion
        self.status = status
        self.lastRefreshDurationMilliseconds = lastRefreshDurationMilliseconds
    }
}
public struct MobileFeedSummary: Codable, Equatable, Sendable {
    public let total: Int
    public let online: Int
    public let offline: Int
    public let accessIssues: Int
    public let slowConnections: Int
    public let alerts: Int
    public let updatesAvailable: Int
    public let restartRequired: Int

    public init(
        total: Int,
        online: Int,
        offline: Int,
        accessIssues: Int,
        slowConnections: Int,
        alerts: Int,
        updatesAvailable: Int,
        restartRequired: Int
    ) {
        self.total = total
        self.online = online
        self.offline = offline
        self.accessIssues = accessIssues
        self.slowConnections = slowConnections
        self.alerts = alerts
        self.updatesAvailable = updatesAvailable
        self.restartRequired = restartRequired
    }
}

public struct MobileFeedService: Codable, Equatable, Sendable {
    public let kind: String
    public let name: String
    public let state: String
    public let detail: String

    public init(kind: String, name: String, state: String, detail: String) {
        self.kind = kind
        self.name = name
        self.state = state
        self.detail = detail
    }
}

public struct MobileFeedWarning: Codable, Equatable, Sendable {
    public let kind: String
    public let title: String
    public let detail: String

    public init(kind: String, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public struct MobileFeedHost: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: String
    public let state: String
    public let status: String
    public let detail: String
    public let checkedAt: Date?
    public let issueTypes: [String]
    public let health: Int?
    public let pingMs: Int?
    public let jitterMs: Int?
    public let packetLossPercent: Double?
    public let sshReadyMs: Int?
    public let fullProbeMs: Int?
    public let operatingSystem: String?
    public let bootDescription: String?
    public let diskPercent: Int?
    public let memoryPercent: Int?
    public let loadAverage: Double?
    public let codexCliVersion: String?
    public let codexMacAppVersion: String?
    public let codexMacAppBuild: String?
    public let restartRequired: Bool?
    public let services: [MobileFeedService]
    public let warnings: [MobileFeedWarning]

    public init(
        id: String,
        name: String,
        platform: String,
        state: String,
        status: String,
        detail: String,
        checkedAt: Date? = nil,
        issueTypes: [String] = [],
        health: Int? = nil,
        pingMs: Int? = nil,
        jitterMs: Int? = nil,
        packetLossPercent: Double? = nil,
        sshReadyMs: Int? = nil,
        fullProbeMs: Int? = nil,
        operatingSystem: String? = nil,
        bootDescription: String? = nil,
        diskPercent: Int? = nil,
        memoryPercent: Int? = nil,
        loadAverage: Double? = nil,
        codexCliVersion: String? = nil,
        codexMacAppVersion: String? = nil,
        codexMacAppBuild: String? = nil,
        restartRequired: Bool? = nil,
        services: [MobileFeedService] = [],
        warnings: [MobileFeedWarning] = []
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.state = state
        self.status = status
        self.detail = detail
        self.checkedAt = checkedAt
        self.issueTypes = issueTypes
        self.health = health
        self.pingMs = pingMs
        self.jitterMs = jitterMs
        self.packetLossPercent = packetLossPercent
        self.sshReadyMs = sshReadyMs
        self.fullProbeMs = fullProbeMs
        self.operatingSystem = operatingSystem
        self.bootDescription = bootDescription
        self.diskPercent = diskPercent
        self.memoryPercent = memoryPercent
        self.loadAverage = loadAverage
        self.codexCliVersion = codexCliVersion
        self.codexMacAppVersion = codexMacAppVersion
        self.codexMacAppBuild = codexMacAppBuild
        self.restartRequired = restartRequired
        self.services = services
        self.warnings = warnings
    }
}

public struct MobileFeedLinuxUpdate: Codable, Equatable, Sendable {
    public let hostId: String
    public let hostName: String
    public let state: String
    public let detail: String
    public let packageManager: String?
    public let availableCount: Int
    public let securityCount: Int
    public let snapCount: Int
    public let flatpakCount: Int
    public let restartRequired: Bool
    public let checkedAt: Date?

    public init(
        hostId: String,
        hostName: String,
        state: String,
        detail: String,
        packageManager: String? = nil,
        availableCount: Int = 0,
        securityCount: Int = 0,
        snapCount: Int = 0,
        flatpakCount: Int = 0,
        restartRequired: Bool = false,
        checkedAt: Date? = nil
    ) {
        self.hostId = hostId
        self.hostName = hostName
        self.state = state
        self.detail = detail
        self.packageManager = packageManager
        self.availableCount = availableCount
        self.securityCount = securityCount
        self.snapCount = snapCount
        self.flatpakCount = flatpakCount
        self.restartRequired = restartRequired
        self.checkedAt = checkedAt
    }
}

public struct MobileFeedIncident: Codable, Equatable, Sendable {
    public let id: String
    public let hostId: String
    public let hostName: String
    public let kind: String
    public let severity: String
    public let title: String
    public let detail: String
    public let startedAt: Date

    public init(
        id: String,
        hostId: String,
        hostName: String,
        kind: String,
        severity: String,
        title: String,
        detail: String,
        startedAt: Date
    ) {
        self.id = id
        self.hostId = hostId
        self.hostName = hostName
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
    }
}

public struct MobileFeedMetric: Codable, Equatable, Sendable {
    public let hostId: String
    public let capturedAt: Date
    public let state: String
    public let pingMs: Int?
    public let jitterMs: Int?
    public let packetLossPercent: Double?
    public let sshReadyMs: Int?
    public let fullProbeMs: Int?
    public let diskPercent: Int?
    public let memoryPercent: Int?
    public let loadAverage: Double?

    public init(
        hostId: String,
        capturedAt: Date,
        state: String,
        pingMs: Int? = nil,
        jitterMs: Int? = nil,
        packetLossPercent: Double? = nil,
        sshReadyMs: Int? = nil,
        fullProbeMs: Int? = nil,
        diskPercent: Int? = nil,
        memoryPercent: Int? = nil,
        loadAverage: Double? = nil
    ) {
        self.hostId = hostId
        self.capturedAt = capturedAt
        self.state = state
        self.pingMs = pingMs
        self.jitterMs = jitterMs
        self.packetLossPercent = packetLossPercent
        self.sshReadyMs = sshReadyMs
        self.fullProbeMs = fullProbeMs
        self.diskPercent = diskPercent
        self.memoryPercent = memoryPercent
        self.loadAverage = loadAverage
    }
}

public struct MobileFeedDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let observer: MobileFeedObserver
    public let summary: MobileFeedSummary
    public let hosts: [MobileFeedHost]
    public let linuxUpdates: [MobileFeedLinuxUpdate]
    public let incidents: [MobileFeedIncident]
    public let metrics: [MobileFeedMetric]

    public init(
        generatedAt: Date = Date(),
        observer: MobileFeedObserver,
        summary: MobileFeedSummary,
        hosts: [MobileFeedHost],
        linuxUpdates: [MobileFeedLinuxUpdate] = [],
        incidents: [MobileFeedIncident] = [],
        metrics: [MobileFeedMetric] = []
    ) {
        schemaVersion = 1
        self.generatedAt = generatedAt
        self.observer = observer
        self.summary = summary
        self.hosts = hosts
        self.linuxUpdates = linuxUpdates
        self.incidents = incidents
        self.metrics = metrics
    }
}

public enum MobileFeedCodec {
    public static func encode(_ document: MobileFeedDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> MobileFeedDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MobileFeedDocument.self, from: data)
    }
}

public enum MobileFeedSanitizer {
    public static func redact(_ value: String) -> String {
        let replacements: [(pattern: String, template: String)] = [
            (#"(?i)https?://[^\s]+"#, "[url]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[address]"),
            (#"(?i)\b(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{0,4}\b"#, "[address]"),
            (#"(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b"#, "[account]"),
            (#"/(Users|home)/[^/\s]+"#, "/$1/[user]"),
        ]
        return replacements.reduce(value) { result, replacement in
            guard let expression = try? NSRegularExpression(
                pattern: replacement.pattern,
                options: []
            ) else { return result }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            return expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement.template
            )
        }
    }
}
