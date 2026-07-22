import Foundation

public struct MobileControlPairingDisplay: Codable, Equatable, Sendable {
    public let code: String
    public let expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

public struct MobileControlPairRequest: Codable, Equatable, Sendable {
    public let code: String
    public let deviceId: String
    public let deviceName: String

    public init(code: String, deviceId: String, deviceName: String) {
        self.code = code
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

public struct MobileControlPairResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceId: String
    public let token: String
    public let controllerId: String
    public let controllerName: String
    public let pairedAt: Date

    public init(
        deviceId: String,
        token: String,
        controllerId: String,
        controllerName: String,
        pairedAt: Date = Date()
    ) {
        schemaVersion = 1
        self.deviceId = deviceId
        self.token = token
        self.controllerId = controllerId
        self.controllerName = controllerName
        self.pairedAt = pairedAt
    }
}

public enum MobileControlAction: String, Codable, CaseIterable, Sendable {
    case refreshHosts = "refresh-hosts"
    case codexCLI = "codex-cli"
    case codexMacApp = "codex-mac-app"
    case linuxOS = "linux-os"
    case restartLinux = "restart-linux"
}

public enum MobileControlActionPolicy {
    public static func acceptsTargetCount(action: MobileControlAction, count: Int) -> Bool {
        switch action {
        case .restartLinux:
            count == 1
        case .refreshHosts, .codexCLI, .codexMacApp, .linuxOS:
            count > 0
        }
    }

    public static func isSupported(
        action: MobileControlAction,
        hostIsOnline: Bool,
        supportsCodexDesktopApp: Bool,
        supportsLinuxUpdates: Bool
    ) -> Bool {
        switch action {
        case .refreshHosts:
            true
        case .codexCLI:
            true
        case .codexMacApp:
            supportsCodexDesktopApp
        case .linuxOS:
            supportsLinuxUpdates
        case .restartLinux:
            supportsLinuxUpdates
        }
    }

    public static func isEligible(
        action: MobileControlAction,
        hostIsOnline: Bool,
        supportsCodexDesktopApp: Bool,
        supportsLinuxUpdates: Bool,
        codexCliUpdateAvailable: Bool,
        codexMacAppUpdateAvailable: Bool,
        linuxUpdateAvailable: Bool,
        restartRequired: Bool
    ) -> Bool {
        switch action {
        case .refreshHosts:
            true
        case .codexCLI:
            codexCliUpdateAvailable
        case .codexMacApp:
            supportsCodexDesktopApp && codexMacAppUpdateAvailable
        case .linuxOS:
            supportsLinuxUpdates && linuxUpdateAvailable
        case .restartLinux:
            hostIsOnline && supportsLinuxUpdates && restartRequired
        }
    }
}

public struct MobileControlJobRequest: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let action: MobileControlAction
    public let targetHostIds: [String]

    public init(requestId: UUID, action: MobileControlAction, targetHostIds: [String]) {
        self.requestId = requestId
        self.action = action
        self.targetHostIds = targetHostIds
    }
}

public struct MobileControlCheckRequest: Codable, Equatable, Sendable {
    public let requestId: UUID

    public init(requestId: UUID) {
        self.requestId = requestId
    }
}

public enum MobileControlJobState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case partial
    case failed

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .partial, .failed: true
        case .queued, .running: false
        }
    }
}

public struct MobileControlCheckProgressItem: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let state: String
    public let detail: String

    public init(id: String, name: String, category: String, state: String, detail: String) {
        self.id = MobileControlCheckProgressPlan.boundedSanitized(id)
        self.name = MobileControlCheckProgressPlan.boundedSanitized(name)
        self.category = MobileControlCheckProgressPlan.boundedSanitized(category)
        self.state = MobileControlCheckProgressPlan.boundedSanitized(state)
        self.detail = MobileControlCheckProgressPlan.boundedSanitized(detail)
    }
}

public enum MobileControlCheckProgressPlan {
    public static let total = 3
    public static let stepIDs = ["fleet", "linux", "publishing"]
    public static let validStates: Set<String> = ["queued", "running", "succeeded", "partial", "failed"]
    private static let terminalStates: Set<String> = ["succeeded", "partial", "failed"]

    private static let definitions: [(id: String, name: String, category: String)] = [
        ("fleet", "Installed versions", "fleet"),
        ("linux", "Linux packages", "linux"),
        ("publishing", "Publish results", "publishing"),
    ]

    public static func initial() -> [MobileControlCheckProgressItem] {
        definitions.map {
            MobileControlCheckProgressItem(
                id: $0.id,
                name: $0.name,
                category: $0.category,
                state: "queued",
                detail: "Waiting"
            )
        }
    }

    public static func normalized(_ items: [MobileControlCheckProgressItem]) -> [MobileControlCheckProgressItem] {
        let itemsByID = Dictionary(
            items.prefix(12).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return definitions.map { definition in
            guard let item = itemsByID[definition.id] else {
                return MobileControlCheckProgressItem(
                    id: definition.id,
                    name: definition.name,
                    category: definition.category,
                    state: "queued",
                    detail: "Waiting"
                )
            }
            return MobileControlCheckProgressItem(
                id: definition.id,
                name: definition.name,
                category: definition.category,
                state: validStates.contains(item.state) ? item.state : "queued",
                detail: sanitizedDetail(item.detail)
            )
        }
    }

    public static func updating(
        _ items: [MobileControlCheckProgressItem]?,
        id: String,
        state: MobileControlJobState,
        detail: String
    ) -> [MobileControlCheckProgressItem] {
        normalized(items ?? initial()).map { item in
            guard item.id == id else { return item }
            return MobileControlCheckProgressItem(
                id: item.id,
                name: item.name,
                category: item.category,
                state: state.rawValue,
                detail: sanitizedDetail(detail)
            )
        }
    }

    public static func completedCount(_ items: [MobileControlCheckProgressItem]?) -> Int {
        items.map { normalized($0) }?.filter { terminalStates.contains($0.state) }.count ?? 0
    }

    public static func failingIncomplete(
        _ items: [MobileControlCheckProgressItem]?,
        detail: String
    ) -> [MobileControlCheckProgressItem] {
        var result = normalized(items ?? initial())
        for stepID in stepIDs {
            guard let item = result.first(where: { $0.id == stepID }),
                  !terminalStates.contains(item.state) else { continue }
            result = updating(
                result,
                id: stepID,
                state: .failed,
                detail: detail
            )
        }
        return result
    }

    public static func boundedCompleted(_ value: Int?) -> Int? {
        value.map { min(total, max(0, $0)) }
    }

    static func boundedSanitized(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(MobileFeedSanitizer.redact(flattened).prefix(240))
    }

    private static func sanitizedDetail(_ detail: String) -> String {
        boundedSanitized(detail)
    }
}

public struct MobileControlCheck: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let requestId: UUID
    public var state: MobileControlJobState
    public var phase: String
    public var detail: String
    public var startedAt: Date?
    public var finishedAt: Date?
    public var completed: Int?
    public var total: Int?
    public var progress: [MobileControlCheckProgressItem]?

    public init(
        id: UUID = UUID(),
        requestId: UUID,
        state: MobileControlJobState = .queued,
        phase: String = "queued",
        detail: String = "Waiting to check for updates",
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        completed: Int? = 0,
        total: Int? = MobileControlCheckProgressPlan.total,
        progress: [MobileControlCheckProgressItem]? = MobileControlCheckProgressPlan.initial()
    ) {
        schemaVersion = 1
        self.id = id
        self.requestId = requestId
        self.state = state
        self.phase = phase
        self.detail = MobileFeedSanitizer.redact(detail)
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.completed = MobileControlCheckProgressPlan.boundedCompleted(completed)
        self.total = total == nil ? nil : MobileControlCheckProgressPlan.total
        self.progress = progress.map(MobileControlCheckProgressPlan.normalized)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, requestId, state, phase, detail, startedAt, finishedAt
        case completed, total, progress
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard decodedSchemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported mobile control check schema"
            )
        }
        schemaVersion = 1
        id = try values.decode(UUID.self, forKey: .id)
        requestId = try values.decode(UUID.self, forKey: .requestId)
        state = try values.decode(MobileControlJobState.self, forKey: .state)
        phase = try values.decode(String.self, forKey: .phase)
        detail = MobileFeedSanitizer.redact(try values.decode(String.self, forKey: .detail))
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt)
        let decodedCompleted = try values.decodeIfPresent(Int.self, forKey: .completed)
        let decodedTotal = try values.decodeIfPresent(Int.self, forKey: .total)
        let decodedProgress = try values.decodeIfPresent([MobileControlCheckProgressItem].self, forKey: .progress)
        completed = MobileControlCheckProgressPlan.boundedCompleted(decodedCompleted)
        total = decodedTotal == nil ? nil : MobileControlCheckProgressPlan.total
        progress = decodedProgress.map(MobileControlCheckProgressPlan.normalized)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(id, forKey: .id)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(state, forKey: .state)
        try values.encode(phase, forKey: .phase)
        try values.encode(MobileFeedSanitizer.redact(detail), forKey: .detail)
        try values.encodeIfPresent(startedAt, forKey: .startedAt)
        try values.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try values.encodeIfPresent(MobileControlCheckProgressPlan.boundedCompleted(completed), forKey: .completed)
        try values.encodeIfPresent(total == nil ? nil : MobileControlCheckProgressPlan.total, forKey: .total)
        try values.encodeIfPresent(progress.map(MobileControlCheckProgressPlan.normalized), forKey: .progress)
    }
}

public enum MobileControlCheckOutcome {
    public static func state(successfulComponents: Int, failedComponents: Int) -> MobileControlJobState {
        guard successfulComponents > 0 else { return .failed }
        if failedComponents == 0 { return .succeeded }
        return successfulComponents > 0 ? .partial : .failed
    }
}

public struct MobileControlCheckCompletion: Equatable, Sendable {
    public let state: MobileControlJobState
    public let detail: String

    public init(state: MobileControlJobState, detail: String) {
        self.state = state
        self.detail = detail
    }
}

public enum MobileControlCheckCompletionPlanner {
    public static func plan(
        successfulSources: Int,
        failedSources: Int,
        feedPublished: Bool
    ) -> MobileControlCheckCompletion {
        let state = MobileControlCheckOutcome.state(
            successfulComponents: successfulSources,
            failedComponents: failedSources + (feedPublished ? 0 : 1)
        )
        let unavailable = max(0, failedSources)
        let sourceDetail = "\(unavailable) source check\(unavailable == 1 ? "" : "s") unavailable"

        switch state {
        case .succeeded:
            return MobileControlCheckCompletion(
                state: state,
                detail: "Checked installed versions, release feeds, and Linux packages"
            )
        case .partial where feedPublished:
            return MobileControlCheckCompletion(
                state: state,
                detail: "Fresh results published · \(sourceDetail)"
            )
        case .partial:
            let detail = unavailable > 0
                ? "Check completed with \(sourceDetail) · fresh status could not be published"
                : "Update sources checked · fresh status could not be published"
            return MobileControlCheckCompletion(state: state, detail: detail)
        case .failed where feedPublished:
            return MobileControlCheckCompletion(
                state: state,
                detail: "Failure results published · no update source returned a usable result"
            )
        case .failed:
            return MobileControlCheckCompletion(
                state: state,
                detail: "Update check failed · no usable source result and fresh status could not be published"
            )
        case .queued, .running:
            return MobileControlCheckCompletion(state: state, detail: "Update check completed")
        }
    }
}

public enum MobileControlRefreshOwnership {
    public static func permits(activeCheckId: UUID?, requestedCheckId: UUID?) -> Bool {
        activeCheckId == requestedCheckId
    }
}

public enum MobileControlReleaseRequestPolicy {
    public static func request(
        url: URL,
        accept: String,
        timeout: TimeInterval = 8,
        bypassCaches: Bool
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: bypassCaches ? .reloadIgnoringLocalAndRemoteCacheData : .useProtocolCachePolicy,
            timeoutInterval: timeout
        )
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if bypassCaches {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        return request
    }
}

public enum MobileControlCheckRetention {
    public static let defaultTerminalLimit = 100

    public static func retained(
        _ checks: [MobileControlCheck],
        terminalLimit: Int = defaultTerminalLimit
    ) -> [MobileControlCheck] {
        let nonterminal = checks.filter { !$0.state.isTerminal }
        let terminal = checks
            .filter(\.state.isTerminal)
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
            .prefix(max(0, terminalLimit))
        return nonterminal + terminal
    }
}

public struct MobileControlHostProgress: Codable, Equatable, Sendable {
    public let hostId: String
    public let phase: String
    public let detail: String

    public init(hostId: String, phase: String, detail: String) {
        self.hostId = hostId
        self.phase = phase
        self.detail = detail
    }
}

public enum MobileControlProgressMapper {
    public static func map(hostId: String, phase: String?, detail: String?) -> MobileControlHostProgress {
        MobileControlHostProgress(
            hostId: hostId,
            phase: phase ?? "queued",
            detail: MobileFeedSanitizer.redact(detail ?? "Waiting")
        )
    }

    public static func isTerminal(_ progress: MobileControlHostProgress) -> Bool {
        ["succeeded", "offline", "failed"].contains(progress.phase)
    }
}

public enum MobileControlRefreshProgress {
    public static func completed(
        hostId: String,
        state: HostState,
        checkedAt: Date?,
        startedAt: Date
    ) -> MobileControlHostProgress {
        guard let checkedAt, checkedAt >= startedAt else {
            return MobileControlHostProgress(
                hostId: hostId,
                phase: "failed",
                detail: "A fresh probe result was not recorded"
            )
        }

        let stateLabel: String
        switch state {
        case .online: stateLabel = "Online"
        case .unreachable: stateLabel = "Offline"
        case .checking: stateLabel = "Checking"
        case .waking: stateLabel = "Waking"
        }
        return MobileControlHostProgress(
            hostId: hostId,
            phase: "succeeded",
            detail: "Fresh result · \(stateLabel)"
        )
    }

    public static func publicationFailed(hostId: String) -> MobileControlHostProgress {
        MobileControlHostProgress(
            hostId: hostId,
            phase: "failed",
            detail: "Fresh probe completed, but the mobile feed could not be published"
        )
    }
}

public enum MobileControlLinuxRestartDecision: Equatable, Sendable {
    case proceed
    case skipNoLongerRequired
    case failOffline
    case failVerification
}

public enum MobileControlLinuxRestartPreflight {
    public static func decision(
        for status: LinuxRestartRequirementStatus
    ) -> MobileControlLinuxRestartDecision {
        switch status {
        case .required:
            .proceed
        case .notRequired:
            .skipNoLongerRequired
        case .offline:
            .failOffline
        case .unsupported, .failed:
            .failVerification
        }
    }

    public static func postflightIsVerified(_ state: LinuxUpdateState) -> Bool {
        state == .current || state == .updateAvailable
    }
}

public enum MobileControlInterruption {
    public static func detail(for action: MobileControlAction) -> String {
        switch action {
        case .refreshHosts:
            "Controller restarted before fresh results were published"
        case .restartLinux:
            "Controller restarted; restart outcome unknown — verify before retrying"
        case .codexCLI, .codexMacApp, .linuxOS:
            "Not completed because the controller restarted"
        }
    }
}

public struct MobileControlJob: Codable, Equatable, Sendable {
    public let id: UUID
    public let requestId: UUID
    public let action: MobileControlAction
    public let targetHostIds: [String]
    public var state: MobileControlJobState
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var completed: Int
    public let total: Int
    public var progress: [MobileControlHostProgress]

    public init(
        id: UUID = UUID(),
        requestId: UUID,
        action: MobileControlAction,
        targetHostIds: [String],
        state: MobileControlJobState = .queued,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        completed: Int = 0,
        progress: [MobileControlHostProgress] = []
    ) {
        self.id = id
        self.requestId = requestId
        self.action = action
        self.targetHostIds = targetHostIds
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.completed = completed
        total = targetHostIds.count
        self.progress = progress
    }
}

public struct MobileControlHostCapability: Codable, Equatable, Sendable {
    public let hostId: String
    public let hostName: String
    public let state: String
    public let actions: [MobileControlAction]
    public let codexCliUpdateAvailable: Bool
    public let codexMacAppUpdateAvailable: Bool
    public let linuxUpdateAvailable: Bool
    public let restartRequired: Bool
    public let linuxCheckedAt: Date?

    public init(
        hostId: String,
        hostName: String,
        state: String,
        actions: [MobileControlAction],
        codexCliUpdateAvailable: Bool,
        codexMacAppUpdateAvailable: Bool,
        linuxUpdateAvailable: Bool,
        restartRequired: Bool,
        linuxCheckedAt: Date? = nil
    ) {
        self.hostId = hostId
        self.hostName = hostName
        self.state = state
        self.actions = actions
        self.codexCliUpdateAvailable = codexCliUpdateAvailable
        self.codexMacAppUpdateAvailable = codexMacAppUpdateAvailable
        self.linuxUpdateAvailable = linuxUpdateAvailable
        self.restartRequired = restartRequired
        self.linuxCheckedAt = linuxCheckedAt
    }
}

public struct MobileControlStatus: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let controllerId: String
    public let controllerName: String
    public let appVersion: String
    public let commandAuthorityEnabled: Bool
    public let jobJournalAvailable: Bool
    public let pairedDeviceCount: Int
    public let busy: Bool
    public let activeJobId: UUID?
    public let checkingUpdates: Bool
    public let activeCheckId: UUID?
    public let latestCodexCliVersion: String?
    public let codexCliCheckedAt: Date?
    public let codexCliCheckFailed: Bool
    public let latestCodexMacAppVersion: String?
    public let latestCodexMacAppBuild: String?
    public let codexMacAppCheckedAt: Date?
    public let codexMacAppCheckFailed: Bool
    public let capabilities: [MobileControlHostCapability]
    public let recentJobs: [MobileControlJob]

    public init(
        generatedAt: Date = Date(),
        controllerId: String,
        controllerName: String,
        appVersion: String,
        commandAuthorityEnabled: Bool,
        jobJournalAvailable: Bool,
        pairedDeviceCount: Int,
        busy: Bool,
        activeJobId: UUID?,
        checkingUpdates: Bool = false,
        activeCheckId: UUID? = nil,
        latestCodexCliVersion: String? = nil,
        codexCliCheckedAt: Date? = nil,
        codexCliCheckFailed: Bool = false,
        latestCodexMacAppVersion: String? = nil,
        latestCodexMacAppBuild: String? = nil,
        codexMacAppCheckedAt: Date? = nil,
        codexMacAppCheckFailed: Bool = false,
        capabilities: [MobileControlHostCapability],
        recentJobs: [MobileControlJob]
    ) {
        schemaVersion = 1
        self.generatedAt = generatedAt
        self.controllerId = controllerId
        self.controllerName = controllerName
        self.appVersion = appVersion
        self.commandAuthorityEnabled = commandAuthorityEnabled
        self.jobJournalAvailable = jobJournalAvailable
        self.pairedDeviceCount = pairedDeviceCount
        self.busy = busy
        self.activeJobId = activeJobId
        self.checkingUpdates = checkingUpdates
        self.activeCheckId = activeCheckId
        self.latestCodexCliVersion = latestCodexCliVersion
        self.codexCliCheckedAt = codexCliCheckedAt
        self.codexCliCheckFailed = codexCliCheckFailed
        self.latestCodexMacAppVersion = latestCodexMacAppVersion
        self.latestCodexMacAppBuild = latestCodexMacAppBuild
        self.codexMacAppCheckedAt = codexMacAppCheckedAt
        self.codexMacAppCheckFailed = codexMacAppCheckFailed
        self.capabilities = capabilities
        self.recentJobs = recentJobs
    }
}

public struct MobileControlAPIErrorBody: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public let code: String
        public let message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public let schemaVersion: Int
    public let error: Detail

    public init(code: String, message: String) {
        schemaVersion = 1
        error = Detail(code: code, message: message)
    }
}

public struct MobileControlHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public enum MobileControlHTTPParseError: String, Equatable, Sendable {
    case malformedRequest
    case headersTooLarge
    case bodyTooLarge
    case unsupportedTransferEncoding
}

public enum MobileControlHTTPParseResult: Equatable, Sendable {
    case incomplete
    case complete(MobileControlHTTPRequest)
    case failure(MobileControlHTTPParseError)
}

public enum MobileControlHTTPRequestParser {
    public static let maximumHeaderBytes = 16 * 1_024
    public static let maximumBodyBytes = 32 * 1_024
    public static let maximumRequestBytes = maximumHeaderBytes + maximumBodyBytes + 4

    public static func parse(_ data: Data) -> MobileControlHTTPParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return data.count > maximumHeaderBytes ? .failure(.headersTooLarge) : .incomplete
        }
        let headerLength = headerRange.lowerBound
        guard headerLength <= maximumHeaderBytes,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .failure(headerLength > maximumHeaderBytes ? .headersTooLarge : .malformedRequest)
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .failure(.malformedRequest) }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0" else {
            return .failure(.malformedRequest)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .failure(.malformedRequest) }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, headers[name] == nil else { return .failure(.malformedRequest) }
            headers[name] = value
        }

        if let transferEncoding = headers["transfer-encoding"],
           !transferEncoding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(.unsupportedTransferEncoding)
        }
        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else { return .failure(.malformedRequest) }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        guard contentLength <= maximumBodyBytes else { return .failure(.bodyTooLarge) }

        let bodyStart = headerRange.upperBound
        let expectedLength = bodyStart + contentLength
        guard expectedLength <= maximumRequestBytes else { return .failure(.bodyTooLarge) }
        guard data.count >= expectedLength else { return .incomplete }
        guard data.count == expectedLength else { return .failure(.malformedRequest) }

        return .complete(MobileControlHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: Data(data[bodyStart..<expectedLength])
        ))
    }
}
