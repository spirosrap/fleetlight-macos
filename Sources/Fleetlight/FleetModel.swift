import AppKit
import Dispatch
import Foundation
import FleetlightCore
import ServiceManagement
import UniformTypeIdentifiers

private struct HistoryWindowCacheKey: Hashable {
    let hostID: String
    let hours: Double
}

private struct TrendSampleCacheKey: Hashable {
    let hostID: String
    let hours: Double
    let maxPoints: Int
}

private struct ReadOnlyUpdateProgressChange {
    let id: String
    let state: MobileControlJobState
    let detail: String
}

private struct ReadOnlyUpdateSourceCounts {
    let successful: Int
    let failed: Int

    var total: Int { successful + failed }

    var state: MobileControlJobState {
        MobileControlCheckOutcome.state(
            successfulComponents: successful,
            failedComponents: failed
        )
    }
}

@MainActor
final class FleetModel: ObservableObject {
    @Published private(set) var snapshots: [String: HostSnapshot]
    @Published private(set) var historyRevision = 0
    private(set) var lastPrimaryRefreshDurationMilliseconds: Int?
    @Published private(set) var lastRefreshDurationMilliseconds: Int?
    @Published private(set) var incidents: [IncidentEvent] = []
    @Published private(set) var activeIncidents: [IncidentEvent] = []
    @Published private(set) var routeTests: [String: [RouteProbeResult]] = [:]
    @Published private(set) var refreshingHostIDs: Set<String> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshQueued = false
    @Published private(set) var isValidatingRoutes = false
    @Published private(set) var codexUpdates: [String: HostCodexUpdateProgress] = [:]
    @Published private(set) var isUpdatingCodex = false
    @Published private(set) var codexDesktopAppUpdates: [String: HostCodexUpdateProgress] = [:]
    @Published private(set) var isUpdatingCodexDesktopApps = false
    @Published private(set) var isUpdatingAllCodex = false
    @Published private(set) var codexUpdateCompletedCount = 0
    @Published private(set) var codexUpdateTotalCount = 0
    @Published private(set) var linuxUpdateSnapshots: [String: LinuxUpdateSnapshot] = LinuxUpdateStore.loadSnapshots()
    @Published private(set) var observerStatusOutcomes: [String: ObserverStatusFetchOutcome] = [:]
    @Published private(set) var isCheckingObserverConsistency = false
    @Published private(set) var linuxUpdates: [String: HostLinuxUpdateProgress] = [:]
    @Published private(set) var isCheckingLinuxUpdates = false
    @Published private(set) var isCheckingLinuxRestartRequirements = false
    @Published private(set) var isUpdatingLinux = false
    @Published private(set) var linuxUpdateCompletedCount = 0
    @Published private(set) var linuxUpdateTotalCount = 0
    @Published private(set) var linuxRestarts: [String: HostLinuxRestartProgress] = [:]
    @Published private(set) var isRestartingLinux = false
    @Published private(set) var linuxRestartCompletedCount = 0
    @Published private(set) var linuxRestartTotalCount = 0
    @Published private(set) var latestCodexVersion: String?
    @Published private(set) var isCheckingCodexRelease = false
    @Published private(set) var codexReleaseCheckFailed = false
    @Published private(set) var latestCodexDesktopAppRelease: CodexDesktopAppRelease?
    @Published private(set) var isCheckingCodexDesktopAppRelease = false
    @Published private(set) var codexDesktopAppReleaseCheckFailed = false
    @Published private(set) var readOnlyUpdateCheck: MobileControlCheck?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var hiddenHostIDs: Set<String>
    @Published private(set) var hosts: [FleetHost]
    @Published var refreshInterval: TimeInterval
    @Published var fleetStatusFilter: FleetStatusFilter
    @Published private(set) var pinnedHostIDs: Set<String>
    @Published private(set) var fleetSortMode: FleetSortMode
    @Published var launchAtLogin = false
    @Published var notificationsEnabled: Bool
    @Published var codexUpdateAlertsEnabled: Bool
    @Published private(set) var performanceThresholds: PerformanceThresholds
    @Published private(set) var mobileControlPairedDeviceCount = MobileControlCredentialStore.shared.count()
    @Published private(set) var mobileControlCommandAuthorityEnabled = UserDefaults.standard.bool(
        forKey: "mobileControlCommandAuthorityEnabled"
    )
    @Published private(set) var mobileControlJobJournalAvailable = true
    @Published private(set) var mobileControlPairingDisplay: MobileControlPairingDisplay?
    @Published var notice: String?

    private var started = false
    private var pollTask: Task<Void, Never>?
    private var observerHeartbeatTask: Task<Void, Never>?
    private var routeValidationTask: Task<Void, Never>?
    private var queuedRefreshTask: Task<Void, Never>?
    private var mobileControlPairingExpiryTask: Task<Void, Never>?
    private var refreshRequestQueue = RefreshRequestQueue()
    private var linuxRefreshDeferralDepth = 0
    private var failureCounts: [String: Int] = [:]
    private var performanceFailureCounts: [String: Int] = [:]
    private var historySamplesByHost: [String: [MetricSample]] = [:]
    private var historyWindowCache: [HistoryWindowCacheKey: [MetricSample]] = [:]
    private var historySummaryCache: [HistoryWindowCacheKey: HistorySummary] = [:]
    private var trendSampleCache: [TrendSampleCacheKey: [MetricSample]] = [:]
    private var nextHistoryPruneAt = Date.distantPast
    private var lastFreshSSHValidationAt: Date?
    private var activeIncidentState = ActiveIncidentState()
    private var codexUpdateBatch: PersistedCodexUpdateBatch?
    private var linuxUpdateBatch: PersistedLinuxUpdateBatch?
    private var lastObserverConsistencyDetail: String?
    private var observerStatusCheckedAt: Date?
    private var codexReleaseCheckedAt: Date?
    private var codexDesktopAppReleaseCheckedAt: Date?
    private var mobileControlPairingChallenge: MobileControlPairingChallenge?
    private var mobileControlJobs: [MobileControlJob] = []
    private var mobileControlActiveJobID: UUID?
    private var mobileControlChecks: [MobileControlCheck] = []
    private var mobileControlActiveCheckID: UUID?

    private static let codexReleaseCheckInterval: TimeInterval = 15 * 60
    private static let failedCodexReleaseRetryInterval: TimeInterval = 5 * 60
    private static let freshSSHValidationInterval: TimeInterval = 10 * 60
    private static let failedLinuxUpdateRecheckInterval: TimeInterval = 15 * 60

    init() {
        let configurationResult = FleetConfigurationStore.loadOrCreate()
        let resolvedHosts = FleetHost.resolvingLocalHost(in: configurationResult.configuration.hosts)
        hosts = resolvedHosts
        snapshots = Dictionary(uniqueKeysWithValues: resolvedHosts.map { ($0.id, HostSnapshot()) })
        let mobileControlJournal = MobileControlJobStore.load()
        mobileControlJobs = mobileControlJournal.jobs
        let mobileControlCheckJournal = MobileControlCheckStore.load()
        mobileControlChecks = mobileControlCheckJournal.checks
        let controlJournalsAvailable = mobileControlJournal.isAvailable
            && mobileControlCheckJournal.isAvailable
        mobileControlJobJournalAvailable = controlJournalsAvailable
        if !controlJournalsAvailable {
            mobileControlCommandAuthorityEnabled = false
            UserDefaults.standard.set(false, forKey: "mobileControlCommandAuthorityEnabled")
        }
        hiddenHostIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenHostIDs") ?? [])
        let configuredInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = configuredInterval >= 30 ? configuredInterval : 60
        fleetStatusFilter = UserDefaults.standard.string(forKey: "fleetStatusFilter")
            .flatMap(FleetStatusFilter.init(rawValue:))
            ?? (UserDefaults.standard.bool(forKey: "attentionOnly") ? .attention : .all)
        pinnedHostIDs = Set(UserDefaults.standard.stringArray(forKey: "pinnedHostIDs") ?? [])
        fleetSortMode = UserDefaults.standard.string(forKey: "fleetSortMode")
            .flatMap(FleetSortMode.init(rawValue:))
            ?? .priority
        let fleetNotificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        notificationsEnabled = fleetNotificationsEnabled
        codexUpdateAlertsEnabled = (UserDefaults.standard.object(forKey: "codexUpdateAlertsEnabled") as? Bool)
            ?? fleetNotificationsEnabled
        performanceThresholds = UserDefaults.standard.data(forKey: "performanceThresholds")
            .flatMap { try? JSONDecoder().decode(PerformanceThresholds.self, from: $0) }
            ?? .default
        latestCodexVersion = UserDefaults.standard.string(forKey: "latestCodexVersion")
        codexReleaseCheckedAt = UserDefaults.standard.object(forKey: "codexReleaseCheckedAt") as? Date
        codexReleaseCheckFailed = UserDefaults.standard.bool(forKey: "codexReleaseCheckFailed")
        if let version = UserDefaults.standard.string(forKey: "latestCodexDesktopAppVersion"),
           let build = UserDefaults.standard.string(forKey: "latestCodexDesktopAppBuild") {
            latestCodexDesktopAppRelease = CodexDesktopAppRelease(version: version, build: build)
        }
        codexDesktopAppReleaseCheckedAt = UserDefaults.standard.object(forKey: "codexDesktopAppReleaseCheckedAt") as? Date
        codexDesktopAppReleaseCheckFailed = UserDefaults.standard.bool(forKey: "codexDesktopAppReleaseCheckFailed")
        notice = configurationResult.notice
        restoreCodexUpdateBatch()
        restoreLinuxUpdateBatch()
        reconcileInterruptedMobileControlJobs()
        reconcileInterruptedMobileControlChecks()
    }

    deinit {
        pollTask?.cancel()
        observerHeartbeatTask?.cancel()
        routeValidationTask?.cancel()
        queuedRefreshTask?.cancel()
        mobileControlPairingExpiryTask?.cancel()
    }

    var attentionSummary: FleetAttentionSummary {
        FleetAttentionAnalyzer.summarize(
            hosts: visibleHosts,
            snapshots: snapshots,
            thresholds: performanceThresholds
        )
    }

    var attentionCount: Int {
        attentionSummary.uniqueAttentionCount
    }

    var menuStatusText: String? {
        attentionSummary.compactDescription
    }

    var onlineCount: Int {
        attentionSummary.onlineCount
    }

    var unreachableCount: Int {
        attentionSummary.unreachableCount
    }

    var accessIssueCount: Int {
        attentionSummary.monitoringAccessIssueCount
    }

    var slowConnectionCount: Int {
        attentionSummary.performanceWarningCount
    }

    var serviceOrResourceAlertCount: Int {
        attentionSummary.serviceOrResourceAlertCount
    }

    var codexUpdateAvailableHosts: [FleetHost] {
        CodexUpdatePlanner.availableHosts(
            hosts: hosts,
            snapshots: snapshots,
            latestVersion: latestCodexVersion
        )
    }

    var codexDesktopAppHosts: [FleetHost] {
        hosts.filter(\.supportsCodexDesktopApp)
    }

    var codexDesktopAppSummary: CodexDesktopAppSummary {
        CodexDesktopAppReportBuilder.summarize(hosts: codexDesktopAppHosts, snapshots: snapshots)
    }

    var codexDesktopAppReleaseSummary: CodexDesktopAppReleaseSummary {
        CodexDesktopAppReleaseChecker.summarize(
            hosts: codexDesktopAppHosts,
            snapshots: snapshots,
            latestRelease: latestCodexDesktopAppRelease
        )
    }

    var codexDesktopAppUpdateAvailableHosts: [FleetHost] {
        codexDesktopAppHosts.filter { host in
            codexDesktopAppReleaseState(for: host) == .updateAvailable
        }
    }

    func codexDesktopAppReleaseState(for host: FleetHost) -> CodexDesktopAppReleaseState {
        CodexDesktopAppReleaseChecker.state(
            snapshot: snapshots[host.id] ?? HostSnapshot(),
            latestRelease: latestCodexDesktopAppRelease
        )
    }

    var codexDesktopAppVerifiedCount: Int {
        codexDesktopAppUpdates.values.filter { $0.phase == .succeeded }.count
    }

    var codexDesktopAppProblemCount: Int {
        codexDesktopAppUpdates.values.filter { $0.phase == .offline || $0.phase == .failed }.count
    }

    var codexUpdateAvailableCount: Int {
        codexUpdateAvailableHosts.count
    }

    var codexUpdateCenterSummary: CodexUpdateCenterSummary {
        CodexUpdateCenterSummary(
            cliUpdateCount: codexUpdateAvailableCount,
            desktopAppUpdateCount: codexDesktopAppReleaseSummary.updateAvailableCount
        )
    }

    var isAnyCodexUpdateRunning: Bool {
        isUpdatingCodex || isUpdatingCodexDesktopApps || isUpdatingAllCodex
    }

    var linuxUpdateHosts: [FleetHost] {
        hosts.filter { host in
            host.supportsLinuxUpdates
                || snapshots[host.id]?.operatingSystem == "Linux"
                || linuxUpdateSnapshots[host.id] != nil
        }
    }

    var linuxUpdateSummary: LinuxUpdateSummary {
        LinuxUpdateAnalyzer.summarize(hosts: linuxUpdateHosts, snapshots: linuxUpdateSnapshots)
    }

    var linuxUpdateAvailableHosts: [FleetHost] {
        LinuxUpdateAnalyzer.availableHosts(hosts: linuxUpdateHosts, snapshots: linuxUpdateSnapshots)
    }

    var linuxRestartRequiredHosts: [FleetHost] {
        LinuxUpdateAnalyzer.restartRequiredHosts(hosts: linuxUpdateHosts, snapshots: linuxUpdateSnapshots)
    }

    var linuxRestartVerificationSummary: LinuxRestartVerificationSummary {
        linuxRestartVerificationSummary(at: Date())
    }

    private func linuxRestartVerificationSummary(at now: Date) -> LinuxRestartVerificationSummary {
        LinuxRestartVerificationAnalyzer.summarize(
            hosts: linuxUpdateHosts,
            snapshots: linuxUpdateSnapshots,
            now: now,
            freshnessInterval: max(5 * 60, refreshInterval * 2.5)
        )
    }

    var linuxRestartVerificationStatusText: String {
        if isCheckingLinuxRestartRequirements { return "Verifying restart status…" }
        let summary = linuxRestartVerificationSummary
        var parts: [String] = []
        if summary.requiredCount > 0 {
            parts.append("\(summary.requiredCount) required")
        }
        if summary.recentCount > 0 {
            parts.append("\(summary.recentCount) recent")
        }
        if summary.staleCount > 0 {
            parts.append("\(summary.staleCount) stale")
        }
        if summary.unverifiedCount > 0 {
            parts.append("\(summary.unverifiedCount) unverified")
        }
        return parts.isEmpty ? "No restart verification yet" : "Restart status · " + parts.joined(separator: " · ")
    }

    var observerHosts: [FleetHost] {
        hosts.filter(\.supportsCodexDesktopApp)
    }

    var observerConsistencySummary: ObserverConsistencySummary {
        ObserverConsistencyAnalyzer.summarize(
            expectedObserverIDs: observerHosts.map(\.id),
            outcomes: observerStatusOutcomes,
            freshnessInterval: observerFreshnessInterval
        )
    }

    private var observerFreshnessInterval: TimeInterval {
        max(5 * 60, refreshInterval * 2.5)
    }

    private var observerMaintenanceActivity: ObserverMaintenanceActivity? {
        if isUpdatingLinux { return .updatingLinux }
        if isRestartingLinux { return .restartingLinux }
        if isCheckingLinuxUpdates { return .checkingLinuxUpdates }
        if isCheckingLinuxRestartRequirements { return .verifyingLinuxRestarts }
        return nil
    }

    private var isAnyUpdateOperationRunningExceptMobileControl: Bool {
        isRunningReadOnlyUpdateCheck || isValidatingRoutes || isAnyCodexUpdateRunning || isCheckingLinuxUpdates || isCheckingLinuxRestartRequirements || isCheckingObserverConsistency || isUpdatingLinux || isRestartingLinux
    }

    var isRunningReadOnlyUpdateCheck: Bool {
        readOnlyUpdateCheck?.state.isTerminal == false
    }

    var readOnlyUpdateCheckStatusText: String? {
        guard let check = readOnlyUpdateCheck else { return nil }
        if check.state == .running,
           let item = check.progress?.first(where: { $0.state == MobileControlJobState.running.rawValue }) {
            return "\(item.name) · \(item.detail)"
        }
        return check.detail
    }

    var isAnyUpdateOperationRunning: Bool {
        mobileControlActiveJobID != nil
            || mobileControlActiveCheckID != nil
            || isAnyUpdateOperationRunningExceptMobileControl
    }

    private var isLinuxRefreshBlocked: Bool {
        linuxRefreshDeferralDepth > 0 || isCheckingLinuxUpdates || isCheckingLinuxRestartRequirements || isUpdatingLinux || isRestartingLinux
    }

    var isManualRefreshDisabled: Bool {
        isRunningReadOnlyUpdateCheck || isRefreshQueued || (!isLinuxRefreshBlocked && (isRefreshing || isValidatingRoutes || !refreshingHostIDs.isEmpty))
    }

    var codexUpdateCenterStatusText: String {
        if isUpdatingAllCodex { return "Updating CLI first, then Mac app" }
        if isCheckingCodexRelease || isCheckingCodexDesktopAppRelease {
            return "Checking CLI and Mac app releases…"
        }
        if codexUpdateCenterSummary.totalUpdateCount > 0 {
            return codexUpdateCenterSummary.detail + " available"
        }
        if codexReleaseCheckFailed && codexDesktopAppReleaseCheckFailed {
            return "Both release feeds are unavailable"
        }
        if codexReleaseCheckFailed || codexDesktopAppReleaseCheckFailed {
            return "No known updates · one release feed unavailable"
        }
        if latestCodexVersion != nil, latestCodexDesktopAppRelease != nil {
            return "No available updates on online machines"
        }
        return "Check both release feeds"
    }

    var codexFleetVersionSummary: CodexFleetVersionSummary {
        CodexFleetVersionAnalyzer.summarize(
            hosts: hosts,
            snapshots: snapshots,
            latestVersion: latestCodexVersion
        )
    }

    func codexFleetVersionState(for host: FleetHost) -> CodexFleetVersionState {
        CodexFleetVersionAnalyzer.state(
            snapshot: snapshots[host.id] ?? HostSnapshot(),
            latestVersion: latestCodexVersion
        )
    }

    var hasComparableOnlineCodexMachine: Bool {
        hosts.contains { host in
            let snapshot = snapshots[host.id]
            return snapshot?.state == .online
                && snapshot?.codexVersion != nil
                && snapshot?.codexVersion != "Not installed"
                && snapshot?.codexVersion != "Unavailable"
        }
    }

    var onlineCodexMachinesAreCurrent: Bool {
        latestCodexVersion != nil
            && !codexReleaseCheckFailed
            && hasComparableOnlineCodexMachine
            && codexUpdateAvailableHosts.isEmpty
    }

    var codexReleaseSummary: String? {
        if let latestCodexVersion {
            if codexUpdateAvailableCount > 0 {
                let qualifier = codexReleaseCheckFailed ? "last known latest" : "latest"
                return "\(codexUpdateAvailableCount) update\(codexUpdateAvailableCount == 1 ? "" : "s") available · \(qualifier) \(latestCodexVersion)"
            }
            if codexReleaseCheckFailed {
                return hasComparableOnlineCodexMachine
                    ? "No known updates · last known latest \(latestCodexVersion)"
                    : "Last known Codex \(latestCodexVersion)"
            }
            return hasComparableOnlineCodexMachine
                ? "Online machines current · latest \(latestCodexVersion)"
                : "Latest Codex \(latestCodexVersion)"
        }
        if isCheckingCodexRelease { return "Checking latest Codex…" }
        if codexReleaseCheckFailed { return "Latest Codex version unavailable" }
        return nil
    }

    var codexReleaseFreshnessText: String {
        ReleaseCheckFreshness.label(
            checkedAt: codexReleaseCheckedAt,
            failed: codexReleaseCheckFailed
        )
    }

    var codexDesktopAppReleaseFreshnessText: String {
        ReleaseCheckFreshness.label(
            checkedAt: codexDesktopAppReleaseCheckedAt,
            failed: codexDesktopAppReleaseCheckFailed
        )
    }

    var codexAvailableUpdateConfirmationText: String {
        let count = codexUpdateAvailableCount
        let target = count == 1 ? "the outdated online machine" : "\(count) outdated online machines"
        if let latestCodexVersion {
            return "Update Codex on \(target) to \(latestCodexVersion)?"
        }
        return "Update Codex on \(target)?"
    }

    var codexAllUpdateConfirmationText: String {
        let target = hosts.count == 1 ? "this machine" : "all \(hosts.count) machines"
        return "Update Codex on \(target)? Offline machines cannot complete until they are reachable."
    }

    var codexUpdateVerifiedCount: Int {
        codexUpdates.values.filter { $0.phase == .succeeded }.count
    }

    var codexUpdateOfflineCount: Int {
        codexUpdates.values.filter { $0.phase == .offline }.count
    }

    var codexUpdateFailedCount: Int {
        codexUpdates.values.filter { $0.phase == .failed }.count
    }

    var codexUpdateProblemCount: Int {
        codexUpdateOfflineCount + codexUpdateFailedCount
    }

    var codexUpdateRetryReadyHosts: [FleetHost] {
        let onlineHostIDs = Set(hosts.compactMap { host in
            snapshots[host.id]?.state == .online ? host.id : nil
        })
        let retryHostIDs = CodexUpdateRecoveryPlanner.retryHostIDs(
            orderedHostIDs: codexUpdateBatch?.targetHostIDs ?? hosts.map(\.id),
            problemHostIDs: codexUpdateProblemHostIDs,
            onlineHostIDs: onlineHostIDs
        )
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        return retryHostIDs.compactMap { hostsByID[$0] }
    }

    var codexUpdateRetryReadyCount: Int {
        codexUpdateRetryReadyHosts.count
    }

    var codexUpdateOutcomeSummary: String? {
        guard !codexUpdates.isEmpty else { return nil }
        let incomplete = codexUpdates.values.filter { !$0.phase.isTerminal }.count
        return CodexUpdateResultPresentation.summary(
            verifiedCount: codexUpdateVerifiedCount,
            offlineCount: codexUpdateOfflineCount,
            failedCount: codexUpdateFailedCount,
            pendingCount: incomplete,
            finishedAt: codexUpdateBatch?.finishedAt
        )
    }

    var codexUpdateResultIsHistorical: Bool {
        codexUpdateBatch?.finishedAt != nil && !isUpdatingCodex
    }

    var codexUpdateOutcomeHelp: String {
        let timestamp = codexUpdateBatch?.finishedAt?.formatted(date: .abbreviated, time: .shortened)
            ?? "an earlier session"
        return "Saved operation result from \(timestamp). Current and Update Available badges come from live probes. Clear Result removes only this saved operation history."
    }

    var codexRetryConfirmationText: String {
        let ready = codexUpdateRetryReadyCount
        let target = ready == 1 ? "the reachable problem machine" : "\(ready) reachable problem machines"
        let remaining = max(0, codexUpdateProblemCount - ready)
        let suffix = remaining == 0
            ? ""
            : " \(remaining) machine\(remaining == 1 ? " is" : "s are") still unreachable and will remain listed."
        return "Retry Codex on \(target)?\(suffix)"
    }

    private var codexUpdateProblemHostIDs: Set<String> {
        Set(codexUpdates.compactMap { entry in
            switch entry.value.phase {
            case .offline, .failed:
                entry.key
            case .notAttempted, .updating, .succeeded:
                nil
            }
        })
    }

    var attentionDescription: String {
        var parts: [String] = []
        if unreachableCount > 0 {
            parts.append("\(unreachableCount) can’t connect")
        }
        if accessIssueCount > 0 {
            parts.append("\(accessIssueCount) access issue\(accessIssueCount == 1 ? "" : "s")")
        }
        if slowConnectionCount > 0 {
            parts.append("\(slowConnectionCount) slow")
        }
        if serviceOrResourceAlertCount > 0 {
            parts.append("\(serviceOrResourceAlertCount) service/resource alert\(serviceOrResourceAlertCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "All visible machines are healthy" : parts.joined(separator: " · ")
    }

    var visibleHosts: [FleetHost] {
        hosts.filter { !hiddenHostIDs.contains($0.id) }
    }

    var displayedHosts: [FleetHost] {
        let filteredHosts = visibleHosts.filter { host in
            FleetAttentionAnalyzer.matches(
                snapshot: snapshots[host.id] ?? HostSnapshot(),
                thresholds: performanceThresholds,
                filter: fleetStatusFilter
            )
        }
        return FleetHostSorter.sort(
            hosts: filteredHosts,
            snapshots: snapshots,
            thresholds: performanceThresholds,
            pinnedHostIDs: pinnedHostIDs,
            mode: fleetSortMode
        )
    }

    var refreshIntervalLabel: String {
        switch Int(refreshInterval) {
        case 30: "30 sec"
        case 60: "1 min"
        case 120: "2 min"
        case 300: "5 min"
        default: "\(Int(refreshInterval)) sec"
        }
    }

    var refreshProgressLabel: String {
        let completed = max(0, hosts.count - refreshingHostIDs.count)
        return completed == 0
            ? "Starting fast refresh…"
            : "Refreshing · \(completed)/\(hosts.count) machines ready"
    }

    var lastRefreshDurationLabel: String? {
        guard let milliseconds = lastRefreshDurationMilliseconds else { return nil }
        return milliseconds >= 1_000
            ? String(format: "%.1f s", Double(milliseconds) / 1_000)
            : "\(milliseconds) ms"
    }

    var menuSymbol: String {
        if isRefreshing && lastRefresh == nil { return "network" }
        if attentionCount > 0 { return "exclamationmark.triangle.fill" }
        if visibleHosts.allSatisfy({ snapshots[$0.id]?.state == .online }) { return "circle.grid.2x2.fill" }
        return "circle.grid.2x2"
    }

    func start() async {
        guard !started else { return }
        started = true
        MobileFeedHTTPServer.shared.start(
            controlHandler: { [weak self] request in
                guard let self else {
                    return MobileControlHTTPResponse(
                        statusCode: 503,
                        reason: "Service Unavailable",
                        body: Data(#"{"schemaVersion":1,"error":{"code":"controller-unavailable","message":"Fleetlight is unavailable"}}"#.utf8)
                    )
                }
                return await self.handleMobileControlHTTPRequest(request)
            },
            localPairingHandler: { [weak self] request in
                guard let self else {
                    return MobileControlHTTPResponse(
                        statusCode: 503,
                        reason: "Service Unavailable",
                        body: Data(#"{"schemaVersion":1,"error":{"code":"controller-unavailable","message":"Fleetlight is unavailable"}}"#.utf8)
                    )
                }
                return await self.handleLocalMobilePairingStartRequest(request)
            }
        )
        scheduleObserverHeartbeat()
        let startupStartedAt = DispatchTime.now().uptimeNanoseconds
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let historyIndexTask = Task.detached(priority: .utility) {
            let samples = await MetricHistoryStore.shared.recent(hours: 7 * 24)
            return HistoryIndexBuilder.build(samples: samples)
        }
        async let loadedIncidents = IncidentStore.shared.recent(limit: 500)
        incidents = await loadedIncidents
        let incidentsReadyMilliseconds = Self.elapsedMilliseconds(since: startupStartedAt)
        activeIncidentState = ActiveIncidentState(events: incidents)
        activeIncidents = activeIncidentState.activeEvents
        for hostID in activeIncidentState.hostDownHostIDs {
            failureCounts[hostID] = 2
        }
        for hostID in activeIncidentState.performanceWarningHostIDs {
            performanceFailureCounts[hostID] = 2
        }
        let refreshTask = Task { await refreshAll() }
        mergeHistoryIndex(await historyIndexTask.value)
        let historyReadyMilliseconds = Self.elapsedMilliseconds(since: startupStartedAt)
        _ = await refreshTask.value
        await ActivityLogger.shared.append(
            event: "startup-performance",
            detail: "incidents=\(incidentsReadyMilliseconds)ms; history=\(historyReadyMilliseconds)ms; refresh=\(lastRefreshDurationMilliseconds ?? 0)ms; total=\(Self.elapsedMilliseconds(since: startupStartedAt))ms"
        )
        if let batch = codexUpdateBatch, batch.finishedAt == nil {
            await resumeCodexUpdateBatch()
        }
        if let batch = linuxUpdateBatch, batch.finishedAt == nil {
            await resumeLinuxUpdateBatch()
        }
        if !isAnyUpdateOperationRunning { schedulePolling() }
    }

    func requestRefreshAll() async {
        guard !isRunningReadOnlyUpdateCheck else {
            notice = "Wait for the read-only update check to finish"
            return
        }
        guard mobileControlActiveCheckID == nil else {
            notice = "Wait for the live update check to finish"
            return
        }
        if !isLinuxRefreshBlocked, isRefreshing || isValidatingRoutes || !refreshingHostIDs.isEmpty {
            notice = "A fleet refresh is already running"
            return
        }

        switch refreshRequestQueue.request(isBlocked: isLinuxRefreshBlocked) {
        case .startNow:
            isRefreshQueued = refreshRequestQueue.isQueued
            _ = await refreshAll()
        case .queued:
            isRefreshQueued = true
            notice = "Refresh queued · it will run automatically after Linux work finishes"
            await ActivityLogger.shared.append(
                event: "refresh-queued",
                detail: "Waiting for Linux maintenance to finish"
            )
        case .alreadyQueued:
            isRefreshQueued = true
            notice = "Refresh is already queued after Linux work"
        }
    }

    private func beginLinuxRefreshDeferral() {
        linuxRefreshDeferralDepth += 1
    }

    private func endLinuxRefreshDeferral() {
        guard linuxRefreshDeferralDepth > 0 else { return }
        linuxRefreshDeferralDepth -= 1
        guard linuxRefreshDeferralDepth == 0 else { return }

        if refreshRequestQueue.isQueued {
            scheduleQueuedRefreshIfNeeded()
        } else if started {
            schedulePolling()
        }
    }

    private func scheduleQueuedRefreshIfNeeded() {
        guard refreshRequestQueue.isQueued, queuedRefreshTask == nil else { return }
        queuedRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.queuedRefreshTask = nil
            await self.runQueuedRefreshIfReady()
        }
    }

    private func runQueuedRefreshIfReady() async {
        let isBlocked = isRunningReadOnlyUpdateCheck
            || mobileControlActiveCheckID != nil
            || isLinuxRefreshBlocked
            || isRefreshing
            || isValidatingRoutes
            || !refreshingHostIDs.isEmpty
        guard refreshRequestQueue.takeIfReady(isBlocked: isBlocked) else {
            isRefreshQueued = refreshRequestQueue.isQueued
            return
        }

        isRefreshQueued = false
        notice = "Running queued fleet refresh…"
        let startedLogTask = Task {
            await ActivityLogger.shared.append(
                event: "queued-refresh-started",
                detail: "Linux maintenance finished"
            )
        }
        let didRefresh = await refreshAll()
        await startedLogTask.value

        if didRefresh {
            await ActivityLogger.shared.append(
                event: "queued-refresh-completed",
                detail: "All machines rechecked"
            )
            notice = "Queued refresh completed · all machines rechecked"
        } else {
            _ = refreshRequestQueue.request(isBlocked: true)
            isRefreshQueued = true
            notice = "Refresh remains queued · waiting for the current operation"
        }

        if started { schedulePolling() }
    }

    @discardableResult
    func refreshAll(
        forceReleaseChecks: Bool = false,
        mobileControlCheckID: UUID? = nil,
        publishFeed: Bool = true
    ) async -> Bool {
        guard MobileControlRefreshOwnership.permits(
            activeCheckId: mobileControlActiveCheckID,
            requestedCheckId: mobileControlCheckID
        ), (!isRunningReadOnlyUpdateCheck || !publishFeed),
           !isRefreshing,
           !isValidatingRoutes,
           refreshingHostIDs.isEmpty,
           !isLinuxRefreshBlocked else { return false }
        let refreshStartedAt = DispatchTime.now().uptimeNanoseconds
        isRefreshing = true
        notice = nil

        let releaseRetryInterval = codexReleaseCheckFailed
            ? Self.failedCodexReleaseRetryInterval
            : Self.codexReleaseCheckInterval
        let shouldCheckCodexRelease = forceReleaseChecks || (codexReleaseCheckedAt.map {
            Date().timeIntervalSince($0) >= releaseRetryInterval
        } ?? true)
        let codexReleaseTask: Task<String?, Never>?
        if shouldCheckCodexRelease {
            isCheckingCodexRelease = true
            codexReleaseTask = Task {
                await Self.fetchLatestCodexRelease(bypassCaches: forceReleaseChecks)
            }
        } else {
            codexReleaseTask = nil
        }

        let appReleaseRetryInterval = codexDesktopAppReleaseCheckFailed
            ? Self.failedCodexReleaseRetryInterval
            : Self.codexReleaseCheckInterval
        let shouldCheckAppRelease = forceReleaseChecks || (codexDesktopAppReleaseCheckedAt.map {
            Date().timeIntervalSince($0) >= appReleaseRetryInterval
        } ?? true)
        let appReleaseTask: Task<String?, Never>?
        if shouldCheckAppRelease {
            isCheckingCodexDesktopAppRelease = true
            appReleaseTask = Task {
                await Self.fetchLatestCodexDesktopAppRelease(bypassCaches: forceReleaseChecks)
            }
        } else {
            appReleaseTask = nil
        }

        let previousSnapshots = snapshots
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        let isInitialRefresh = lastRefresh == nil
        let hasRemoteRoutes = hosts.contains { !$0.isLocal && !$0.routes.isEmpty }
        let shouldValidateFreshSSH = hasRemoteRoutes && (lastFreshSSHValidationAt.map {
            Date().timeIntervalSince($0) >= Self.freshSSHValidationInterval
        } ?? false)
        refreshingHostIDs = Set(hosts.map(\.id))
        var probeLogEntries: [ActivityLogEntry] = []
        var pendingTransitions: [(FleetHost, HostSnapshot?, HostSnapshot)] = []
        var firstHostReadyMilliseconds: Int?

        await withTaskGroup(of: (String, HostSnapshot).self) { group in
            for host in hosts {
                group.addTask {
                    let snapshot = await Self.probe(host: host)
                    return (host.id, snapshot)
                }
            }

            for await (alias, snapshot) in group {
                guard let host = hostsByID[alias] else { continue }
                let previous = previousSnapshots[alias]
                snapshots[alias] = snapshot
                refreshingHostIDs.remove(alias)
                if firstHostReadyMilliseconds == nil {
                    firstHostReadyMilliseconds = Self.elapsedMilliseconds(since: refreshStartedAt)
                }
                pendingTransitions.append((host, previous, snapshot))
                probeLogEntries.append(probeLogEntry(hostID: alias, snapshot: snapshot))
            }
        }
        refreshingHostIDs.removeAll()
        if lastFreshSSHValidationAt == nil {
            lastFreshSSHValidationAt = Date()
        }
        lastPrimaryRefreshDurationMilliseconds = Self.elapsedMilliseconds(since: refreshStartedAt)
        for (host, previous, current) in pendingTransitions {
            await handleTransitions(
                host: host,
                previous: previous,
                current: current,
                isInitialRefresh: isInitialRefresh
            )
        }
        await ActivityLogger.shared.append(probeLogEntries)

        await reconcileLinuxRestartRequirementsFromProbes()
        await revalidateFailedLinuxUpdateProgress()
        await revalidateRecoveredLinuxUpdateHosts()
        await refreshObserverConsistency()

        if let codexReleaseTask {
            applyCodexReleaseResult(await codexReleaseTask.value)
        }
        if let appReleaseTask {
            applyCodexDesktopAppReleaseResult(await appReleaseTask.value)
        }
        await reconcileCodexUpdateFailuresVerifiedCurrent()
        await postCodexUpdateAlertsIfNeeded()
        let historyBatch = await MetricHistoryStore.shared.append(snapshots: snapshots)
        appendHistoryBatch(historyBatch)
        lastRefresh = Date()
        lastRefreshDurationMilliseconds = Self.elapsedMilliseconds(since: refreshStartedAt)
        if publishFeed { publishMobileFeed() }
        isRefreshing = false
        let coldValidationStarted = shouldValidateFreshSSH && startFreshSSHValidation()
        await ActivityLogger.shared.append(
            event: "refresh-performance",
            detail: "first=\(firstHostReadyMilliseconds ?? 0)ms; primary=\(lastPrimaryRefreshDurationMilliseconds ?? 0)ms; total=\(lastRefreshDurationMilliseconds ?? 0)ms; hosts=\(hosts.count); coldValidationStarted=\(coldValidationStarted)"
        )
        scheduleQueuedRefreshIfNeeded()
        return true
    }

    @discardableResult
    private func startFreshSSHValidation() -> Bool {
        guard !isValidatingRoutes, !isAnyUpdateOperationRunning else { return false }
        let targets = hosts.filter { !$0.isLocal && !$0.routes.isEmpty }
        guard !targets.isEmpty else { return false }

        isValidatingRoutes = true
        lastFreshSSHValidationAt = Date()
        routeValidationTask = Task { [weak self] in
            let results = await Self.validateFreshSSHRoutes(hosts: targets)
            guard let self else { return }
            guard !Task.isCancelled else {
                self.isValidatingRoutes = false
                self.lastFreshSSHValidationAt = .distantPast
                self.routeValidationTask = nil
                self.scheduleQueuedRefreshIfNeeded()
                return
            }

            let entries = results.map { hostID, snapshot in
                ActivityLogEntry(
                    event: snapshot.state == .online ? "ssh-cold-validation" : "ssh-cold-validation-failed",
                    host: hostID,
                    detail: snapshot.state == .online
                        ? "Verified fresh via \(snapshot.routeName ?? "configured route") in \(snapshot.probeDurationMilliseconds ?? 0) ms"
                        : snapshot.detail
                )
            }
            await ActivityLogger.shared.append(entries)
            self.isValidatingRoutes = false
            self.routeValidationTask = nil
            self.scheduleQueuedRefreshIfNeeded()
        }
        return true
    }

    nonisolated private static func validateFreshSSHRoutes(
        hosts: [FleetHost]
    ) async -> [(String, HostSnapshot)] {
        await withTaskGroup(
            of: (String, HostSnapshot).self,
            returning: [(String, HostSnapshot)].self
        ) { group in
            for host in hosts {
                group.addTask {
                    var retiredEveryRoute = true
                    for route in host.routes {
                        guard !Task.isCancelled else { break }
                        guard let arguments = SSHMultiplexing.retireArguments(routeAlias: route.alias) else {
                            retiredEveryRoute = false
                            continue
                        }
                        let retirement = await CommandRunner.runBufferedAsync(
                            executable: "/usr/bin/ssh",
                            arguments: arguments,
                            timeout: 2
                        )
                        if !SSHMultiplexing.retirementSucceeded(retirement) {
                            retiredEveryRoute = false
                        }
                    }
                    guard !Task.isCancelled else {
                        return (host.id, HostSnapshot(state: .checking, detail: "Validation cancelled"))
                    }
                    return (
                        host.id,
                        await probeRoutes(
                            host: host,
                            includeServices: false,
                            multiplex: retiredEveryRoute
                        )
                    )
                }
            }

            var results: [(String, HostSnapshot)] = []
            results.reserveCapacity(hosts.count)
            for await result in group where result.1.state != .checking {
                results.append(result)
            }
            return results
        }
    }

    private func reconcileLinuxRestartRequirementsFromProbes() async {
        let results = linuxUpdateHosts.compactMap { host -> (String, Bool, Date)? in
            guard let snapshot = snapshots[host.id],
                  snapshot.state == .online,
                  let rebootRequired = snapshot.linuxRestartRequired else { return nil }
            return (host.id, rebootRequired, snapshot.checkedAt ?? Date())
        }
        await applyLinuxRestartRequirements(results)
    }

    private func verifyLinuxRestartRequirementsRemotely() async {
        let targets = linuxUpdateHosts.filter {
            snapshots[$0.id]?.state == .online
        }
        guard !targets.isEmpty else { return }

        let results = await withTaskGroup(
            of: (String, LinuxRestartRequirementOutcome, Date).self,
            returning: [(String, LinuxRestartRequirementOutcome, Date)].self
        ) { group in
            for host in targets {
                let routeAlias = snapshots[host.id]?.routeAlias ?? host.routes.first?.alias
                group.addTask {
                    let result = await Self.runLinuxRestartRequirementCheck(host: host, routeAlias: routeAlias)
                    return (host.id, LinuxRestartRequirementParser.outcome(from: result), Date())
                }
            }

            var values: [(String, LinuxRestartRequirementOutcome, Date)] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        let verified = results.compactMap { hostID, outcome, checkedAt -> (String, Bool, Date)? in
            switch outcome.status {
            case .required: (hostID, true, checkedAt)
            case .notRequired: (hostID, false, checkedAt)
            case .offline, .unsupported, .failed: nil
            }
        }
        await applyLinuxRestartRequirements(verified)
    }

    private func applyLinuxRestartRequirements(_ results: [(String, Bool, Date)]) async {
        reconcileClearedRestartDetails()
        guard !results.isEmpty else { return }

        var reconciledSnapshots = linuxUpdateSnapshots
        var clearedHostIDs: Set<String> = []
        var snapshotsChanged = false
        for (hostID, rebootRequired, restartCheckedAt) in results {
            let cached = reconciledSnapshots[hostID] ?? LinuxUpdateSnapshot()
            let updated = cached.replacingRebootRequired(rebootRequired, checkedAt: restartCheckedAt)
            if updated != cached {
                reconciledSnapshots[hostID] = updated
                snapshotsChanged = true
            }

            guard cached.rebootRequired != rebootRequired else { continue }
            if rebootRequired {
                await ActivityLogger.shared.append(
                    event: "linux-restart-requirement-detected",
                    host: hostID,
                    detail: "Live reboot flag is present"
                )
            } else {
                clearedHostIDs.insert(hostID)
                await ActivityLogger.shared.append(
                    event: "linux-restart-requirement-cleared",
                    host: hostID,
                    detail: "Live reboot flag is no longer present"
                )
            }
        }
        if snapshotsChanged {
            linuxUpdateSnapshots = reconciledSnapshots
            LinuxUpdateStore.saveSnapshots(reconciledSnapshots)
        }
        if !clearedHostIDs.isEmpty {
            reconcileClearedRestartDetails(for: clearedHostIDs)
        }
    }

    @discardableResult
    private func publishLocalObserverStatus(at publishedAt: Date = Date()) -> FleetHost? {
        guard let localObserver = observerHosts.first(where: \.isLocal) else { return nil }
        let verification = linuxRestartVerificationSummary(at: publishedAt)
        let localSnapshot = ObserverStatusSnapshot(
            generatedAt: publishedAt,
            appVersion: FleetlightVersion.currentDisplayLabel,
            linuxHostCount: linuxUpdateHosts.count,
            restartRequiredCount: verification.requiredCount,
            recentVerificationCount: verification.recentCount,
            staleVerificationCount: verification.staleCount,
            unverifiedCount: verification.unverifiedCount,
            maintenanceActivity: observerMaintenanceActivity
        )
        let didSave = ObserverStatusStore.save(localSnapshot)

        var outcomes = observerStatusOutcomes
        outcomes[localObserver.id] = didSave
            ? ObserverStatusFetchOutcome(
                state: .available,
                snapshot: localSnapshot,
                detail: "Local observer status published"
            )
            : ObserverStatusFetchOutcome(
                state: .invalid,
                detail: "Local observer status could not be saved"
            )
        observerStatusOutcomes = outcomes
        return localObserver
    }

    private func scheduleObserverHeartbeat() {
        guard observerHeartbeatTask == nil else { return }
        publishLocalObserverStatus()
        observerHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(ObserverStatusRefreshPolicy.heartbeatInterval))
                } catch {
                    return
                }
                guard let self else { return }
                self.publishLocalObserverStatus()
            }
        }
    }

    private func refreshObserverConsistency(forceRemoteFetch: Bool = false) async {
        guard publishLocalObserverStatus() != nil else { return }
        let cachedOutcomes = observerStatusOutcomes
        let remoteObservers = observerHosts.filter { !$0.isLocal }
        let observerCacheInterval = ObserverStatusRefreshPolicy.remoteCacheInterval(
            expectedCount: observerHosts.count,
            outcomes: Dictionary(uniqueKeysWithValues: observerHosts.compactMap { host in
                cachedOutcomes[host.id].map { (host.id, $0) }
            }),
            now: Date(),
            freshnessInterval: observerFreshnessInterval
        )
        let remoteStatusIsDue = forceRemoteFetch
            || observerStatusCheckedAt.map { Date().timeIntervalSince($0) >= observerCacheInterval } != false
            || remoteObservers.contains { cachedOutcomes[$0.id] == nil }
        var remoteResults: [String: ObserverStatusFetchOutcome] = [:]
        if remoteStatusIsDue {
            await withTaskGroup(of: (String, ObserverStatusFetchOutcome).self) { group in
                for host in remoteObservers {
                    let routeAlias = snapshots[host.id]?.routeAlias ?? host.routes.first?.alias
                    group.addTask {
                        let result = await Self.runObserverStatusCheck(host: host, routeAlias: routeAlias)
                        return (host.id, ObserverStatusParser.outcome(from: result))
                    }
                }
                for await (hostID, outcome) in group {
                    remoteResults[hostID] = outcome
                }
            }
            observerStatusCheckedAt = Date()
        }
        if !remoteResults.isEmpty {
            var mergedOutcomes = observerStatusOutcomes
            for (hostID, outcome) in remoteResults {
                mergedOutcomes[hostID] = outcome
            }
            observerStatusOutcomes = mergedOutcomes
        }

        let summary = observerConsistencySummary
        if summary.detail != lastObserverConsistencyDetail {
            await ActivityLogger.shared.append(
                event: "observer-consistency",
                detail: "state=\(summary.state.rawValue); available=\(summary.availableCount)/\(summary.expectedCount); \(summary.detail)"
            )
            lastObserverConsistencyDetail = summary.detail
        }
    }

    private func revalidateRecoveredLinuxUpdateHosts() async {
        let targets = LinuxUpdateRecoveryPlanner.hostsToRecheck(
            hosts: linuxUpdateHosts,
            hostSnapshots: snapshots,
            updateSnapshots: linuxUpdateSnapshots
        )
        guard !targets.isEmpty else { return }

        for host in targets {
            let previous = linuxUpdateSnapshots[host.id] ?? LinuxUpdateSnapshot()
            linuxUpdateSnapshots[host.id] = LinuxUpdateSnapshot(
                state: .checking,
                distribution: previous.distribution,
                kernelVersion: previous.kernelVersion,
                packageManager: previous.packageManager,
                packageUpdateCount: previous.packageUpdateCount,
                securityUpdateCount: previous.securityUpdateCount,
                snapUpdateCount: previous.snapUpdateCount,
                flatpakUpdateCount: previous.flatpakUpdateCount,
                availablePackages: previous.availablePackages,
                rebootRequired: previous.rebootRequired,
                restartCheckedAt: previous.restartCheckedAt,
                checkedAt: previous.checkedAt,
                detail: "Machine is online · rechecking cached package status…"
            )
        }

        await withTaskGroup(of: (String, LinuxUpdateSnapshot).self) { group in
            for host in targets {
                let routeAlias = snapshots[host.id]?.routeAlias ?? host.routes.first?.alias
                group.addTask {
                    let result = await Self.runLinuxUpdateRecoveryCheck(host: host, routeAlias: routeAlias)
                    return (host.id, LinuxUpdateCheckParser.snapshot(from: result))
                }
            }
            for await (hostID, snapshot) in group {
                linuxUpdateSnapshots[hostID] = snapshot
                await ActivityLogger.shared.append(
                    event: "linux-update-recovery-checked",
                    host: hostID,
                    detail: snapshot.detail
                )
            }
        }

        LinuxUpdateStore.saveSnapshots(linuxUpdateSnapshots)
        reconcileClearedRestartDetails()
    }

    private func revalidateFailedLinuxUpdateProgress() async {
        guard !isAnyUpdateOperationRunning,
              linuxUpdateBatch?.finishedAt != nil else { return }

        let retryCutoff = Date().addingTimeInterval(-Self.failedLinuxUpdateRecheckInterval)
        let targets = linuxUpdateHosts.filter { host in
            guard snapshots[host.id]?.state == .online,
                  let progress = linuxUpdates[host.id],
                  progress.phase == .failed || progress.phase == .offline else { return false }
            guard let checkedAt = linuxUpdateSnapshots[host.id]?.checkedAt else { return true }
            return checkedAt <= retryCutoff
        }
        guard !targets.isEmpty else { return }

        await withTaskGroup(of: (String, LinuxUpdateSnapshot).self) { group in
            for host in targets {
                let routeAlias = snapshots[host.id]?.routeAlias ?? host.routes.first?.alias
                group.addTask {
                    let snapshot = await Self.runLinuxUpdateCheckWithRetry(
                        host: host,
                        routeAlias: routeAlias
                    )
                    return (host.id, snapshot)
                }
            }
            for await (hostID, snapshot) in group {
                linuxUpdateSnapshots[hostID] = snapshot
                await ActivityLogger.shared.append(
                    event: "linux-update-failure-rechecked",
                    host: hostID,
                    detail: snapshot.detail
                )
            }
        }

        LinuxUpdateStore.saveSnapshots(linuxUpdateSnapshots)
        reconcileClearedRestartDetails()
        await reconcileLinuxUpdateFailuresVerifiedCurrent(for: Set(targets.map(\.id)))
    }

    private func reconcileLinuxUpdateFailuresVerifiedCurrent(for checkedHostIDs: Set<String>) async {
        guard !checkedHostIDs.isEmpty, !linuxUpdates.isEmpty else { return }

        var reconciledUpdates = linuxUpdates
        var reconciled: [(hostID: String, detail: String)] = []
        for hostID in checkedHostIDs {
            guard let progress = linuxUpdates[hostID],
                  progress.phase == .failed || progress.phase == .offline,
                  let snapshot = linuxUpdateSnapshots[hostID],
                  snapshot.state == .current,
                  snapshot.packageManager == "apt",
                  let checkedAt = snapshot.checkedAt else { continue }
            if let batch = linuxUpdateBatch,
               batch.targetHostIDs.contains(hostID),
               checkedAt < batch.startedAt {
                continue
            }

            let detail = linuxUpdateReconciliationDetail(for: snapshot)
            reconciledUpdates[hostID] = HostLinuxUpdateProgress(phase: .succeeded, detail: detail)
            reconciled.append((hostID, detail))
        }

        guard !reconciled.isEmpty else { return }
        linuxUpdates = reconciledUpdates
        linuxUpdateCompletedCount = reconciledUpdates.values.filter { $0.phase.isTerminal }.count
        persistLinuxUpdateBatch()
        for result in reconciled {
            await ActivityLogger.shared.append(
                event: "linux-update-failure-reconciled",
                host: result.hostID,
                detail: result.detail
            )
        }
    }

    private func linuxUpdateReconciliationDetail(for snapshot: LinuxUpdateSnapshot) -> String {
        snapshot.rebootRequired
            ? "Verified current after prior update failure · restart required"
            : "Verified current after prior update failure"
    }

    @discardableResult
    private func publishMobileFeed() -> Bool {
        let feedHosts = visibleHosts
        let hostsByID = Dictionary(uniqueKeysWithValues: feedHosts.map { ($0.id, $0) })

        let mobileHosts = feedHosts.map { host -> MobileFeedHost in
            let snapshot = snapshots[host.id] ?? HostSnapshot()
            let connection = FleetConnectionClassifier.status(for: snapshot)
            let warnings = PerformanceEvaluator.warnings(
                snapshot: snapshot,
                thresholds: performanceThresholds
            )
            let hasAlerts = (snapshot.diskPercent ?? 0) >= 90
                || snapshot.services.contains(where: { $0.state.needsAttention })
            var issueTypes: [String] = []
            switch connection {
            case .offline: issueTypes.append("offline")
            case .accessIssue: issueTypes.append("access")
            case .pending, .online: break
            }
            if !warnings.isEmpty { issueTypes.append("slow") }
            if hasAlerts { issueTypes.append("alerts") }
            if linuxUpdateSnapshots[host.id]?.rebootRequired == true { issueTypes.append("restart") }
            if linuxUpdateSnapshots[host.id]?.state == .updateAvailable { issueTypes.append("updates") }

            let state: String
            switch connection {
            case .offline: state = "offline"
            case .accessIssue: state = "access"
            case .pending: state = "unknown"
            case .online where hasAlerts: state = "attention"
            case .online where !warnings.isEmpty: state = "slow"
            case .online: state = "online"
            }

            let availability = historySummary(for: host.id).availabilityPercent
            return MobileFeedHost(
                id: host.id,
                name: host.displayName,
                platform: snapshot.operatingSystem ?? (host.supportsCodexDesktopApp ? "macOS" : "Unknown"),
                state: state,
                status: state,
                detail: MobileFeedSanitizer.redact(snapshot.detail),
                checkedAt: snapshot.checkedAt,
                issueTypes: issueTypes,
                health: HealthScorer.score(
                    snapshot: snapshot,
                    availability: availability,
                    thresholds: performanceThresholds
                ),
                pingMs: snapshot.pingMilliseconds,
                jitterMs: snapshot.pingJitterMilliseconds,
                packetLossPercent: snapshot.packetLossPercent,
                sshReadyMs: snapshot.connectionReadyMilliseconds,
                fullProbeMs: snapshot.probeDurationMilliseconds,
                operatingSystem: snapshot.operatingSystem,
                bootDescription: snapshot.bootDescription,
                diskPercent: snapshot.diskPercent,
                memoryPercent: snapshot.memoryPercent,
                loadAverage: snapshot.loadAverage,
                codexCliVersion: snapshot.codexVersion,
                codexMacAppVersion: snapshot.codexDesktopAppVersion,
                codexMacAppBuild: snapshot.codexDesktopAppBuild,
                restartRequired: linuxUpdateSnapshots[host.id]?.rebootRequired ?? snapshot.linuxRestartRequired,
                services: snapshot.services.map {
                    MobileFeedService(
                        kind: $0.kind.rawValue,
                        name: $0.kind.displayName,
                        state: $0.state.rawValue,
                        detail: MobileFeedSanitizer.redact($0.detail)
                    )
                },
                warnings: warnings.map {
                    MobileFeedWarning(
                        kind: $0.kind.rawValue,
                        title: $0.kind.displayName,
                        detail: MobileFeedSanitizer.redact($0.detail)
                    )
                }
            )
        }

        let linuxUpdates = feedHosts.compactMap { host -> MobileFeedLinuxUpdate? in
            guard host.supportsLinuxUpdates else { return nil }
            let snapshot = linuxUpdateSnapshots[host.id] ?? LinuxUpdateSnapshot()
            return MobileFeedLinuxUpdate(
                hostId: host.id,
                hostName: host.displayName,
                state: snapshot.state.rawValue,
                detail: MobileFeedSanitizer.redact(snapshot.detail),
                packageManager: snapshot.packageManager,
                availableCount: snapshot.totalUpdateCount,
                securityCount: snapshot.securityUpdateCount,
                snapCount: snapshot.snapUpdateCount,
                flatpakCount: snapshot.flatpakUpdateCount,
                restartRequired: snapshot.rebootRequired,
                checkedAt: snapshot.checkedAt
            )
        }

        let recentIncidents = incidents.prefix(30).map { incident in
            let severity: String
            switch incident.kind {
            case .hostDown, .serviceAttention, .diskWarning, .wakeUnverified, .performanceAttention:
                severity = "warning"
            case .hostRecovered, .serviceRecovered, .routeChanged, .wakeVerified, .performanceRecovered:
                severity = "info"
            }
            return MobileFeedIncident(
                id: incident.id.uuidString,
                hostId: incident.hostID,
                hostName: hostsByID[incident.hostID]?.displayName ?? incident.hostID,
                kind: incident.kind.rawValue,
                severity: severity,
                title: incident.title,
                detail: MobileFeedSanitizer.redact(incident.detail),
                startedAt: incident.timestamp
            )
        }

        let metrics = feedHosts.flatMap { host in
            chartSamples(for: host.id, hours: 24, maxPoints: 48).map { sample in
                MobileFeedMetric(
                    hostId: host.id,
                    capturedAt: sample.timestamp,
                    state: sample.state.rawValue,
                    pingMs: sample.pingMilliseconds,
                    jitterMs: sample.pingJitterMilliseconds,
                    packetLossPercent: sample.packetLossPercent,
                    sshReadyMs: sample.connectionReadyMilliseconds,
                    fullProbeMs: sample.effectiveProbeDurationMilliseconds,
                    diskPercent: sample.diskPercent,
                    memoryPercent: sample.memoryPercent,
                    loadAverage: sample.loadAverage
                )
            }
        }

        let document = MobileFeedDocument(
            generatedAt: Date(),
            observer: MobileFeedObserver(
                id: FleetObserver.currentDisplayName.lowercased(),
                name: FleetObserver.currentDisplayName,
                appVersion: FleetlightVersion.currentDisplayLabel,
                lastRefreshDurationMilliseconds: lastRefreshDurationMilliseconds
            ),
            summary: MobileFeedSummary(
                total: feedHosts.count,
                online: onlineCount,
                offline: unreachableCount,
                accessIssues: accessIssueCount,
                slowConnections: slowConnectionCount,
                alerts: serviceOrResourceAlertCount,
                updatesAvailable: linuxUpdates.filter { $0.availableCount > 0 }.count,
                restartRequired: linuxUpdates.filter(\.restartRequired).count
            ),
            hosts: mobileHosts,
            linuxUpdates: linuxUpdates,
            incidents: recentIncidents,
            metrics: metrics
        )
        return MobileFeedStore.save(document)
    }


    func checkObserverConsistencyNow() async {
        guard !isAnyUpdateOperationRunning, !isRefreshing else {
            notice = "Wait for the current operation to finish"
            return
        }
        guard !observerHosts.isEmpty else {
            notice = "No Mac observers are configured"
            return
        }

        pollTask?.cancel()
        isCheckingObserverConsistency = true
        await ActivityLogger.shared.append(
            event: "observer-consistency-check-started",
            detail: "expected=\(observerHosts.count)"
        )
        await refreshObserverConsistency(forceRemoteFetch: true)
        let summary = observerConsistencySummary
        await ActivityLogger.shared.append(
            event: "observer-consistency-check-finished",
            detail: "state=\(summary.state.rawValue); available=\(summary.availableCount)/\(summary.expectedCount)"
        )
        isCheckingObserverConsistency = false
        if started { schedulePolling() }
        notice = summary.detail
    }

    func verifyLinuxRestartRequirementsNow() async {
        guard !isAnyUpdateOperationRunning else {
            notice = "Wait for the current update operation to finish"
            return
        }
        guard !isRefreshing else {
            notice = "Wait for the current fleet check to finish"
            return
        }
        guard !linuxUpdateHosts.isEmpty else {
            notice = "No Linux machines are configured"
            return
        }

        pollTask?.cancel()
        beginLinuxRefreshDeferral()
        isCheckingLinuxRestartRequirements = true
        publishLocalObserverStatus()
        defer {
            isCheckingLinuxRestartRequirements = false
            publishLocalObserverStatus()
            endLinuxRefreshDeferral()
        }
        notice = "Verifying Linux restart status…"
        await ActivityLogger.shared.append(
            event: "linux-restart-requirement-check-started",
            detail: "targets=\(linuxUpdateHosts.count)"
        )
        await verifyLinuxRestartRequirementsRemotely()
        await refreshObserverConsistency(forceRemoteFetch: true)
        let summary = linuxRestartVerificationSummary
        await ActivityLogger.shared.append(
            event: "linux-restart-requirement-check-finished",
            detail: "required=\(summary.requiredCount); recent=\(summary.recentCount); stale=\(summary.staleCount); unverified=\(summary.unverifiedCount)"
        )
        notice = linuxRestartVerificationStatusText
    }

    private func reconcileClearedRestartDetails(for scopedHostIDs: Set<String>? = nil) {
        var clearedHostIDs = Set(linuxUpdateSnapshots.compactMap { hostID, snapshot in
            snapshot.rebootRequired ? nil : hostID
        })
        if let scopedHostIDs {
            clearedHostIDs.formIntersection(scopedHostIDs)
        }
        guard !clearedHostIDs.isEmpty else { return }

        var reconciledUpdates = linuxUpdates
        var updatesChanged = false
        for hostID in clearedHostIDs {
            guard let progress = reconciledUpdates[hostID], progress.phase == .succeeded else { continue }
            let detail = LinuxRestartDetailReconciler.clearingRestartRequirement(from: progress.detail)
            guard detail != progress.detail else { continue }
            reconciledUpdates[hostID] = HostLinuxUpdateProgress(phase: progress.phase, detail: detail)
            updatesChanged = true
        }
        if updatesChanged {
            linuxUpdates = reconciledUpdates
            if var batch = linuxUpdateBatch {
                batch.progress = reconciledUpdates
                linuxUpdateBatch = batch
                LinuxUpdateStore.saveBatch(batch)
            }
        }

        var reconciledRestarts = linuxRestarts
        var restartsChanged = false
        for hostID in clearedHostIDs {
            guard let progress = reconciledRestarts[hostID], progress.phase == .succeeded else { continue }
            let detail = LinuxRestartDetailReconciler.clearingRestartRequirement(from: progress.detail)
            guard detail != progress.detail else { continue }
            reconciledRestarts[hostID] = HostLinuxRestartProgress(phase: progress.phase, detail: detail)
            restartsChanged = true
        }
        if restartsChanged {
            linuxRestarts = reconciledRestarts
        }
    }

    private func applyCodexReleaseResult(_ registryJSON: String?) {
        let checkedAt = Date()
        codexReleaseCheckedAt = checkedAt
        UserDefaults.standard.set(checkedAt, forKey: "codexReleaseCheckedAt")
        isCheckingCodexRelease = false

        guard let registryJSON,
              let version = CodexReleaseChecker.latestVersion(fromRegistryJSON: registryJSON) else {
            codexReleaseCheckFailed = true
            UserDefaults.standard.set(true, forKey: "codexReleaseCheckFailed")
            return
        }
        latestCodexVersion = version
        codexReleaseCheckFailed = false
        UserDefaults.standard.set(version, forKey: "latestCodexVersion")
        UserDefaults.standard.set(false, forKey: "codexReleaseCheckFailed")
    }

    func checkCodexReleaseNow() async {
        guard !isCheckingCodexRelease else { return }
        guard mobileControlActiveCheckID == nil else { return }
        guard !isUpdatingLinux, !isCheckingLinuxUpdates, !isRestartingLinux else { return }
        guard !isRefreshing else {
            notice = "Wait for the current fleet check to finish"
            return
        }
        isCheckingCodexRelease = true
        notice = nil
        applyCodexReleaseResult(await Self.fetchLatestCodexRelease(bypassCaches: true))
        await reconcileCodexUpdateFailuresVerifiedCurrent()
        await postCodexUpdateAlertsIfNeeded()
        if codexReleaseCheckFailed {
            notice = "Couldn’t check the latest Codex version"
        } else if let latestCodexVersion {
            notice = "Latest stable Codex is \(latestCodexVersion)"
        }
    }

    private func applyCodexDesktopAppReleaseResult(_ appcastXML: String?) {
        let checkedAt = Date()
        codexDesktopAppReleaseCheckedAt = checkedAt
        UserDefaults.standard.set(checkedAt, forKey: "codexDesktopAppReleaseCheckedAt")
        isCheckingCodexDesktopAppRelease = false

        guard let appcastXML,
              let release = CodexDesktopAppReleaseChecker.latestRelease(fromAppcastXML: appcastXML) else {
            codexDesktopAppReleaseCheckFailed = true
            UserDefaults.standard.set(true, forKey: "codexDesktopAppReleaseCheckFailed")
            return
        }
        latestCodexDesktopAppRelease = release
        codexDesktopAppReleaseCheckFailed = false
        UserDefaults.standard.set(release.version, forKey: "latestCodexDesktopAppVersion")
        UserDefaults.standard.set(release.build, forKey: "latestCodexDesktopAppBuild")
        UserDefaults.standard.set(false, forKey: "codexDesktopAppReleaseCheckFailed")
    }

    func checkCodexDesktopAppReleaseNow() async {
        guard !isCheckingCodexDesktopAppRelease else { return }
        guard mobileControlActiveCheckID == nil else { return }
        guard !isUpdatingLinux, !isCheckingLinuxUpdates, !isRestartingLinux else { return }
        isCheckingCodexDesktopAppRelease = true
        notice = nil
        applyCodexDesktopAppReleaseResult(
            await Self.fetchLatestCodexDesktopAppRelease(bypassCaches: true)
        )
        await postCodexUpdateAlertsIfNeeded()
        if codexDesktopAppReleaseCheckFailed {
            notice = "Couldn’t check the latest Codex Mac app release"
        } else if let release = latestCodexDesktopAppRelease {
            notice = codexDesktopAppReleaseSummary.updateAvailableCount > 0
                ? "Codex Mac app \(release.version) is available"
                : "Codex Mac apps are current at \(release.version)"
        }
    }

    func checkAllUpdatesNow() async {
        guard !isRunningReadOnlyUpdateCheck else { return }
        guard !isRefreshQueued, !isRefreshing, !isAnyUpdateOperationRunning else {
            notice = "Wait for the current fleet operation to finish"
            return
        }

        notice = nil
        let startedAt = Date()
        readOnlyUpdateCheck = MobileControlCheck(
            requestId: UUID(),
            state: .queued,
            phase: "queued",
            detail: "Waiting to run the read-only update check"
        )
        await ActivityLogger.shared.append(
            event: "read-only-update-check-started",
            detail: "source=local"
        )

        let completion = await runReadOnlyUpdateCheck(
            startedAt: startedAt,
            mobileControlCheckID: nil
        ) { [weak self] phase, detail, completed, changes in
            guard let self, var check = self.readOnlyUpdateCheck else { return false }
            self.applyReadOnlyUpdateProgress(
                to: &check,
                phase: phase,
                detail: detail,
                completed: completed,
                changes: changes,
                startedAt: check.startedAt == nil ? startedAt : nil
            )
            self.readOnlyUpdateCheck = check
            return true
        }

        let finishedAt = Date()
        if var check = readOnlyUpdateCheck {
            check.state = completion?.state ?? .failed
            check.phase = "complete"
            check.detail = completion?.detail ?? "The read-only update check could not finish"
            check.finishedAt = finishedAt
            readOnlyUpdateCheck = check
        }
        let finalState = completion?.state ?? .failed
        notice = completion?.detail ?? "The read-only update check could not finish"
        await ActivityLogger.shared.append(
            event: "read-only-update-check-finished",
            detail: "source=local; state=\(finalState.rawValue)"
        )
        scheduleQueuedRefreshIfNeeded()
        if started { schedulePolling() }
    }

    private func runReadOnlyUpdateCheck(
        startedAt: Date,
        mobileControlCheckID: UUID?,
        onProgress: (_ phase: String, _ detail: String, _ completed: Int, _ changes: [ReadOnlyUpdateProgressChange]) -> Bool
    ) async -> MobileControlCheckCompletion? {
        guard onProgress(
            "fleet",
            "Refreshing installed versions and release sources",
            0,
            [ReadOnlyUpdateProgressChange(id: "fleet", state: .running, detail: "Refreshing installed versions and release sources")]
        ) else { return nil }

        let refreshed = await refreshAll(
            forceReleaseChecks: true,
            mobileControlCheckID: mobileControlCheckID,
            publishFeed: false
        )
        guard refreshed else {
            let failureDetail = "The fresh fleet probe could not start"
            _ = onProgress(
                "publishing",
                failureDetail,
                MobileControlCheckProgressPlan.total,
                [
                    ReadOnlyUpdateProgressChange(id: "fleet", state: .failed, detail: failureDetail),
                    ReadOnlyUpdateProgressChange(id: "linux", state: .failed, detail: "Not run because the fleet probe failed"),
                    ReadOnlyUpdateProgressChange(id: "publishing", state: .failed, detail: "No fresh result was available to publish"),
                ]
            )
            return MobileControlCheckCompletionPlanner.plan(
                successfulSources: 0,
                failedSources: max(1, visibleHosts.count + 2),
                feedPublished: false
            )
        }

        let fleetCounts = readOnlyFleetSourceCounts(startedAt: startedAt)
        let fleetDetail = "\(fleetCounts.successful)/\(fleetCounts.total) installed and release sources checked"
        guard onProgress(
            "linux",
            "Refreshing Linux package metadata",
            1,
            [
                ReadOnlyUpdateProgressChange(id: "fleet", state: fleetCounts.state, detail: fleetDetail),
                ReadOnlyUpdateProgressChange(id: "linux", state: .running, detail: "Refreshing Linux package metadata"),
            ]
        ) else { return nil }

        let linuxTargets = linuxUpdateHosts
        if !linuxTargets.isEmpty {
            await checkLinuxUpdates(forMobileControlCheck: mobileControlCheckID)
        }
        let linuxCounts = readOnlyLinuxSourceCounts(startedAt: startedAt)
        let linuxState: MobileControlJobState = linuxTargets.isEmpty ? .succeeded : linuxCounts.state
        let linuxDetail = linuxTargets.isEmpty
            ? "No Linux machines are configured"
            : "\(linuxCounts.successful)/\(linuxCounts.total) Linux package sources checked"
        guard onProgress(
            "publishing",
            "Publishing the refreshed mobile feed",
            2,
            [
                ReadOnlyUpdateProgressChange(id: "linux", state: linuxState, detail: linuxDetail),
                ReadOnlyUpdateProgressChange(id: "publishing", state: .running, detail: "Publishing the refreshed mobile feed"),
            ]
        ) else { return nil }

        let feedPublished = publishMobileFeed()
        let publishingState: MobileControlJobState = feedPublished ? .succeeded : .failed
        let publishingDetail = feedPublished
            ? "Fresh status published"
            : "Fresh status could not be published"
        guard onProgress(
            "publishing",
            publishingDetail,
            3,
            [ReadOnlyUpdateProgressChange(id: "publishing", state: publishingState, detail: publishingDetail)]
        ) else { return nil }

        return MobileControlCheckCompletionPlanner.plan(
            successfulSources: fleetCounts.successful + linuxCounts.successful,
            failedSources: fleetCounts.failed + linuxCounts.failed,
            feedPublished: feedPublished
        )
    }

    private func readOnlyFleetSourceCounts(startedAt: Date) -> ReadOnlyUpdateSourceCounts {
        var successful = visibleHosts.filter { host in
            snapshots[host.id]?.state == .online
                && snapshots[host.id]?.checkedAt.map { $0 >= startedAt } == true
        }.count
        var failed = max(0, visibleHosts.count - successful)
        if codexReleaseCheckFailed || codexReleaseCheckedAt.map({ $0 >= startedAt }) != true {
            failed += 1
        } else {
            successful += 1
        }
        if codexDesktopAppReleaseCheckFailed
            || codexDesktopAppReleaseCheckedAt.map({ $0 >= startedAt }) != true {
            failed += 1
        } else {
            successful += 1
        }
        return ReadOnlyUpdateSourceCounts(successful: successful, failed: failed)
    }

    private func readOnlyLinuxSourceCounts(startedAt: Date) -> ReadOnlyUpdateSourceCounts {
        var successful = 0
        var failed = 0
        for host in linuxUpdateHosts {
            let snapshot = linuxUpdateSnapshots[host.id]
            guard snapshot?.checkedAt.map({ $0 >= startedAt }) == true else {
                failed += 1
                continue
            }
            switch snapshot?.state {
            case .current, .updateAvailable: successful += 1
            case .none, .notChecked, .checking, .offline, .unsupported, .failed: failed += 1
            }
        }
        return ReadOnlyUpdateSourceCounts(successful: successful, failed: failed)
    }

    private func applyReadOnlyUpdateProgress(
        to check: inout MobileControlCheck,
        phase: String,
        detail: String,
        completed: Int,
        changes: [ReadOnlyUpdateProgressChange],
        startedAt: Date? = nil
    ) {
        check.state = .running
        check.phase = phase
        check.detail = MobileFeedSanitizer.redact(detail)
        if let startedAt { check.startedAt = startedAt }
        check.completed = MobileControlCheckProgressPlan.boundedCompleted(completed)
        check.total = MobileControlCheckProgressPlan.total
        for change in changes {
            check.progress = MobileControlCheckProgressPlan.updating(
                check.progress,
                id: change.id,
                state: change.state,
                detail: change.detail
            )
        }
    }

    private func failIncompleteReadOnlyUpdateProgress(
        to check: inout MobileControlCheck,
        detail: String
    ) {
        let items = MobileControlCheckProgressPlan.failingIncomplete(
            check.progress,
            detail: detail
        )
        check.progress = items
        check.total = MobileControlCheckProgressPlan.total
        check.completed = MobileControlCheckProgressPlan.completedCount(items)
    }

    func updateAllAvailableCodex() async {
        guard !isAnyUpdateOperationRunning else { return }
        guard !isRefreshing else {
            notice = "Wait for the current fleet check to finish"
            return
        }

        let cliTargets = codexUpdateAvailableHosts
        let desktopTargets = codexDesktopAppUpdateAvailableHosts
        let total = cliTargets.count + desktopTargets.count
        guard total > 0 else {
            notice = "No Codex updates are available"
            return
        }

        isUpdatingAllCodex = true
        defer { isUpdatingAllCodex = false }
        await ActivityLogger.shared.append(
            event: "codex-update-center-started",
            detail: "cli=\(cliTargets.count); mac-app=\(desktopTargets.count)"
        )

        if !cliTargets.isEmpty {
            await performCodexUpdates(on: cliTargets)
        }
        guard !Task.isCancelled else { return }
        if !desktopTargets.isEmpty {
            await performCodexDesktopAppUpdates(on: desktopTargets)
        }

        let cliVerified = cliTargets.filter { codexUpdates[$0.id]?.phase == .succeeded }.count
        let desktopVerified = desktopTargets.filter { codexDesktopAppUpdates[$0.id]?.phase == .succeeded }.count
        let verified = cliVerified + desktopVerified
        let problems = total - verified
        await ActivityLogger.shared.append(
            event: "codex-update-center-finished",
            detail: "verified=\(verified); attention=\(problems)"
        )
        notice = problems == 0
            ? "All \(verified) available Codex update\(verified == 1 ? "" : "s") verified"
            : "Codex Update Center: \(verified) verified · \(problems) need attention"
    }

    func checkLinuxUpdates() async {
        await checkLinuxUpdates(forMobileControlCheck: nil)
    }

    private func checkLinuxUpdates(forMobileControlCheck checkID: UUID?) async {
        guard mobileControlActiveCheckID == checkID,
              !isCheckingLinuxUpdates,
              !isCheckingLinuxRestartRequirements,
              !isUpdatingLinux,
              !isRestartingLinux,
              !isAnyCodexUpdateRunning else { return }
        guard !isRefreshing else {
            notice = "Wait for the current fleet check to finish"
            return
        }
        let targets = linuxUpdateHosts
        guard !targets.isEmpty else {
            notice = "No Linux update machines are configured"
            return
        }

        pollTask?.cancel()
        beginLinuxRefreshDeferral()
        isCheckingLinuxUpdates = true
        publishLocalObserverStatus()
        defer {
            isCheckingLinuxUpdates = false
            publishLocalObserverStatus()
            endLinuxRefreshDeferral()
        }
        notice = "Checking Linux updates on \(targets.count) machine\(targets.count == 1 ? "" : "s")…"
        for host in targets {
            let previous = linuxUpdateSnapshots[host.id]
            linuxUpdateSnapshots[host.id] = LinuxUpdateSnapshot(
                state: .checking,
                distribution: previous?.distribution,
                kernelVersion: previous?.kernelVersion,
                packageManager: previous?.packageManager,
                packageUpdateCount: previous?.packageUpdateCount ?? 0,
                securityUpdateCount: previous?.securityUpdateCount ?? 0,
                snapUpdateCount: previous?.snapUpdateCount ?? 0,
                flatpakUpdateCount: previous?.flatpakUpdateCount ?? 0,
                availablePackages: previous?.availablePackages ?? [],
                rebootRequired: previous?.rebootRequired ?? false,
                restartCheckedAt: previous?.restartCheckedAt,
                checkedAt: previous?.checkedAt,
                detail: "Refreshing package metadata…"
            )
        }

        await withTaskGroup(of: (String, LinuxUpdateSnapshot).self) { group in
            for host in targets {
                let routeAlias = snapshots[host.id]?.routeAlias ?? host.routes.first?.alias
                group.addTask {
                    let snapshot = await Self.runLinuxUpdateCheckWithRetry(
                        host: host,
                        routeAlias: routeAlias
                    )
                    return (host.id, snapshot)
                }
            }
            for await (hostID, snapshot) in group {
                linuxUpdateSnapshots[hostID] = snapshot
                await ActivityLogger.shared.append(
                    event: "linux-update-checked",
                    host: hostID,
                    detail: snapshot.detail
                )
            }
        }

        LinuxUpdateStore.saveSnapshots(linuxUpdateSnapshots)
        reconcileClearedRestartDetails()
        await reconcileLinuxUpdateFailuresVerifiedCurrent(for: Set(targets.map(\.id)))
        let summary = linuxUpdateSummary
        notice = summary.updateAvailableCount > 0
            ? "\(summary.totalPendingUpdates) Linux update\(summary.totalPendingUpdates == 1 ? "" : "s") available on \(summary.updateAvailableCount) machine\(summary.updateAvailableCount == 1 ? "" : "s")"
            : "Linux update check complete · no known updates"
    }

    func updateLinux(on host: FleetHost) async {
        guard linuxUpdateHosts.contains(where: { $0.id == host.id }) else {
            notice = "Linux updates are not enabled for \(host.displayName)"
            return
        }
        await performLinuxUpdates(on: [host])
    }

    func updateLinuxOnAvailableHosts() async {
        beginLinuxRefreshDeferral()
        defer { endLinuxRefreshDeferral() }

        if linuxUpdateHosts.contains(where: {
            let state = linuxUpdateSnapshots[$0.id]?.state ?? .notChecked
            return state == .notChecked || state == .failed
        }) {
            await checkLinuxUpdates()
        }
        let targets = linuxUpdateAvailableHosts
        guard !targets.isEmpty else {
            notice = "No Linux package updates are available"
            return
        }
        await performLinuxUpdates(on: targets)
    }

    private func resumeLinuxUpdateBatch() async {
        guard let batch = linuxUpdateBatch, batch.finishedAt == nil else { return }
        let targets = batch.targetHostIDs.compactMap { hostID in
            linuxUpdateHosts.first { $0.id == hostID }
        }
        await performLinuxUpdates(on: targets, resuming: true)
    }

    private func performLinuxUpdates(on targets: [FleetHost], resuming: Bool = false) async {
        guard mobileControlActiveCheckID == nil,
              !isUpdatingLinux,
              !isCheckingLinuxUpdates,
              !isRestartingLinux,
              !isAnyCodexUpdateRunning else { return }
        guard resuming || !targets.isEmpty else { return }
        guard !isRefreshing else {
            notice = "Wait for the current fleet check to finish"
            return
        }

        pollTask?.cancel()
        beginLinuxRefreshDeferral()
        isUpdatingLinux = true
        publishLocalObserverStatus()
        defer {
            isUpdatingLinux = false
            publishLocalObserverStatus()
            endLinuxRefreshDeferral()
        }
        if resuming, let batch = linuxUpdateBatch {
            linuxUpdateTotalCount = batch.targetHostIDs.count
            linuxUpdateCompletedCount = batch.progress.values.filter { $0.phase.isTerminal }.count
            let remaining = max(0, linuxUpdateTotalCount - linuxUpdateCompletedCount)
            notice = "Resuming Linux updates on \(remaining) machine\(remaining == 1 ? "" : "s")"
        } else {
            linuxUpdateTotalCount = targets.count
            linuxUpdateCompletedCount = 0
            linuxUpdates = Dictionary(uniqueKeysWithValues: targets.map {
                ($0.id, HostLinuxUpdateProgress(phase: .notAttempted, detail: "Waiting"))
            })
            linuxUpdateBatch = PersistedLinuxUpdateBatch(
                targetHostIDs: targets.map(\.id),
                progress: linuxUpdates
            )
            persistLinuxUpdateBatch()
            notice = targets.count == 1
                ? "Updating Linux on \(targets[0].displayName)"
                : "Updating Linux sequentially on \(targets.count) machines"
            if let batch = linuxUpdateBatch {
                await ActivityLogger.shared.append(
                    event: "linux-update-started",
                    detail: "batch=\(batch.id.uuidString); targets=\(targets.count)"
                )
            }
        }

        for host in targets {
            guard !(linuxUpdates[host.id]?.phase.isTerminal ?? false) else { continue }
            linuxUpdates[host.id] = HostLinuxUpdateProgress(
                phase: .updating,
                detail: "Updating system, Snap, and Flatpak packages…"
            )
            persistLinuxUpdateBatch()

            let routeAlias = snapshots[host.id]?.routeAlias ?? host.routes.first?.alias
            let updateResult = await Self.runLinuxUpdate(host: host, routeAlias: routeAlias)
            let outcome = LinuxUpdateParser.outcome(from: updateResult)
            var phase: HostLinuxUpdatePhase
            var detail = outcome.detail
            var event: String

            switch outcome.status {
            case .succeeded:
                let verificationResult = await Self.runLinuxUpdateCheck(host: host, routeAlias: routeAlias)
                let verified = LinuxUpdateCheckParser.snapshot(from: verificationResult)
                linuxUpdateSnapshots[host.id] = verified
                LinuxUpdateStore.saveSnapshots(linuxUpdateSnapshots)
                switch verified.state {
                case .current:
                    phase = .succeeded
                    detail = verified.rebootRequired || outcome.rebootRequired
                        ? "Verified current · restart required"
                        : "Verified current"
                    event = "linux-update-succeeded"
                case .updateAvailable:
                    phase = .succeeded
                    detail = "Update completed · \(verified.totalUpdateCount) still available"
                    if verified.rebootRequired || outcome.rebootRequired {
                        detail += " · restart required"
                    }
                    event = "linux-update-partial"
                case .offline:
                    phase = .offline
                    detail = "Update ran, but verification could not reconnect"
                    event = "linux-update-verification-offline"
                case .notChecked, .checking, .unsupported, .failed:
                    phase = .failed
                    detail = "Update ran, but verification failed: \(verified.detail)"
                    event = "linux-update-verification-failed"
                }
            case .offline:
                phase = .offline
                event = "linux-update-offline"
            case .failed:
                phase = .failed
                event = "linux-update-failed"
                let recoveryResult = await Self.runLinuxUpdateCheck(host: host, routeAlias: routeAlias)
                let recoverySnapshot = LinuxUpdateCheckParser.snapshot(from: recoveryResult)
                linuxUpdateSnapshots[host.id] = recoverySnapshot
                LinuxUpdateStore.saveSnapshots(linuxUpdateSnapshots)
                await ActivityLogger.shared.append(
                    event: "linux-update-post-failure-checked",
                    host: host.id,
                    detail: recoverySnapshot.detail
                )
                if recoverySnapshot.state == .current,
                   recoverySnapshot.packageManager == "apt" {
                    phase = .succeeded
                    detail = linuxUpdateReconciliationDetail(for: recoverySnapshot)
                    event = "linux-update-failure-reconciled"
                }
            }

            linuxUpdates[host.id] = HostLinuxUpdateProgress(phase: phase, detail: detail)
            linuxUpdateCompletedCount += 1
            persistLinuxUpdateBatch()
            await ActivityLogger.shared.append(event: event, host: host.id, detail: detail)
        }

        if var batch = linuxUpdateBatch {
            batch.finishedAt = Date()
            batch.progress = linuxUpdates
            linuxUpdateBatch = batch
            persistLinuxUpdateBatch()
        }

        let succeeded = linuxUpdates.values.filter { $0.phase == .succeeded }.count
        let offline = linuxUpdates.values.filter { $0.phase == .offline }.count
        let failed = linuxUpdates.values.filter { $0.phase == .failed }.count
        await ActivityLogger.shared.append(
            event: "linux-update-finished",
            detail: "verified=\(succeeded); offline=\(offline); failed=\(failed)"
        )

        notice = offline == 0 && failed == 0
            ? "Linux updates verified on \(succeeded) machine\(succeeded == 1 ? "" : "s")"
            : "Linux update: \(succeeded) verified · \(offline) offline · \(failed) failed"
    }

    private func restoreLinuxUpdateBatch() {
        guard var batch = LinuxUpdateStore.loadBatch() else { return }
        let knownHostIDs = Set(hosts.map(\.id))
        for hostID in batch.targetHostIDs {
            if !knownHostIDs.contains(hostID) {
                batch.progress[hostID] = HostLinuxUpdateProgress(
                    phase: .failed,
                    detail: "Failed — machine is no longer configured"
                )
            } else if batch.progress[hostID]?.phase == .updating {
                batch.progress[hostID] = HostLinuxUpdateProgress(
                    phase: .notAttempted,
                    detail: "Not completed — retrying after restart"
                )
            } else if batch.progress[hostID] == nil {
                batch.progress[hostID] = HostLinuxUpdateProgress(
                    phase: .notAttempted,
                    detail: "Not attempted yet"
                )
            }
        }
        linuxUpdateBatch = batch
        linuxUpdates = batch.progress
        linuxUpdateTotalCount = batch.targetHostIDs.count
        linuxUpdateCompletedCount = batch.progress.values.filter { $0.phase.isTerminal }.count
        reconcileClearedRestartDetails()
        if let reconciledBatch = linuxUpdateBatch {
            LinuxUpdateStore.saveBatch(reconciledBatch)
        }
    }

    private func persistLinuxUpdateBatch() {
        guard var batch = linuxUpdateBatch else { return }
        batch.progress = linuxUpdates
        linuxUpdateBatch = batch
        LinuxUpdateStore.saveBatch(batch)
    }

    func restartLinux(on host: FleetHost) async {
        await restartLinux(on: host, mobileControlJobID: nil)
    }

    private func restartLinux(on host: FleetHost, mobileControlJobID: UUID?) async {
        guard linuxUpdateSnapshots[host.id]?.rebootRequired == true else {
            notice = "Linux does not currently report a required restart for \(host.displayName)"
            return
        }
        await performLinuxRestarts(on: [host], mobileControlJobID: mobileControlJobID)
    }

    func restartLinuxOnRequiredHosts() async {
        let targets = linuxRestartRequiredHosts
        guard !targets.isEmpty else {
            notice = "No Linux machines currently require a restart"
            return
        }
        await performLinuxRestarts(on: targets, mobileControlJobID: nil)
    }

    private func performLinuxRestarts(on targets: [FleetHost], mobileControlJobID: UUID?) async {
        guard mobileControlActiveJobID == mobileControlJobID,
              mobileControlActiveCheckID == nil,
              !isAnyUpdateOperationRunningExceptMobileControl,
              !targets.isEmpty else { return }
        pollTask?.cancel()
        beginLinuxRefreshDeferral()
        isRestartingLinux = true
        publishLocalObserverStatus()
        defer {
            isRestartingLinux = false
            publishLocalObserverStatus()
            endLinuxRefreshDeferral()
        }
        if isRefreshing {
            notice = "Finishing the current fleet check before restarting…"
            let refreshDeadline = Date().addingTimeInterval(30)
            while isRefreshing, Date() < refreshDeadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !isRefreshing else {
                notice = "The fleet check is still running · try Restart again"
                return
            }
        }
        linuxRestartTotalCount = targets.count
        linuxRestartCompletedCount = 0
        linuxRestarts = Dictionary(uniqueKeysWithValues: targets.map {
            ($0.id, HostLinuxRestartProgress(phase: .waiting, detail: "Waiting"))
        })
        notice = targets.count == 1
            ? "Restarting \(targets[0].displayName)"
            : "Restarting Linux sequentially on \(targets.count) machines"
        await ActivityLogger.shared.append(
            event: "linux-restart-started",
            detail: "targets=\(targets.count)"
        )

        for host in targets {
            linuxRestarts[host.id] = HostLinuxRestartProgress(
                phase: .issuing,
                detail: "Issuing confirmed restart…"
            )
            let routeAlias = snapshots[host.id]?.routeAlias ?? host.routes.first?.alias
            let commandResult = await Self.runLinuxRestart(host: host, routeAlias: routeAlias)
            let outcome = LinuxRestartParser.outcome(from: commandResult)
            var finalPhase: HostLinuxRestartPhase
            var finalDetail: String
            var event: String

            switch outcome.status {
            case .scheduled:
                linuxRestarts[host.id] = HostLinuxRestartProgress(
                    phase: .waitingForOffline,
                    detail: "Restart issued · waiting for shutdown…"
                )
                await ActivityLogger.shared.append(
                    event: "linux-restart-issued",
                    host: host.id,
                    detail: outcome.bootDescriptionBeforeRestart.map { "boot-before=\($0)" } ?? "boot-before=unknown"
                )

                let previousBoot = outcome.bootDescriptionBeforeRestart ?? snapshots[host.id]?.bootDescription
                var sawOffline = false
                var restartedSnapshot: HostSnapshot?

                let restartDeadline = Date().addingTimeInterval(5 * 60)
                while Date() < restartDeadline {
                    try? await Task.sleep(for: .seconds(4))
                    let candidate = await Self.probe(host: host)
                    if candidate.state == .online {
                        let bootChanged = previousBoot != nil
                            && candidate.bootDescription != nil
                            && candidate.bootDescription != previousBoot
                        if sawOffline || bootChanged {
                            restartedSnapshot = candidate
                            break
                        }
                    } else {
                        sawOffline = true
                        linuxRestarts[host.id] = HostLinuxRestartProgress(
                            phase: .waitingForOnline,
                            detail: "Shutdown observed · waiting for SSH to return…"
                        )
                    }
                }

                if let restartedSnapshot {
                    snapshots[host.id] = restartedSnapshot
                    linuxRestarts[host.id] = HostLinuxRestartProgress(
                        phase: .verifying,
                        detail: "Restart verified · rechecking Linux status…"
                    )
                    let verificationResult = await Self.runLinuxUpdateCheck(host: host, routeAlias: restartedSnapshot.routeAlias ?? routeAlias)
                    let verified = LinuxUpdateCheckParser.snapshot(from: verificationResult)
                    if MobileControlLinuxRestartPreflight.postflightIsVerified(verified.state) {
                        linuxUpdateSnapshots[host.id] = verified
                        LinuxUpdateStore.saveSnapshots(linuxUpdateSnapshots)
                        finalDetail = verified.rebootRequired
                            ? "Restart verified · Linux still requests another restart"
                            : "Restart verified · machine is back online"
                        finalPhase = .succeeded
                        event = verified.rebootRequired
                            ? "linux-restart-still-required"
                            : "linux-restart-verified"
                    } else {
                        finalPhase = .failed
                        finalDetail = "Restart occurred, but Linux status verification failed"
                        event = "linux-restart-status-check-failed"
                    }
                } else if sawOffline {
                    finalPhase = .offline
                    finalDetail = "Restart issued, but the machine did not return within 5 minutes"
                    event = "linux-restart-return-timeout"
                } else {
                    finalPhase = .failed
                    finalDetail = "Restart issued, but shutdown could not be verified within 5 minutes"
                    event = "linux-restart-unverified"
                }
            case .offline:
                finalPhase = .offline
                finalDetail = outcome.detail
                event = "linux-restart-offline"
            case .failed:
                finalPhase = .failed
                finalDetail = outcome.detail
                event = "linux-restart-failed"
            }

            linuxRestarts[host.id] = HostLinuxRestartProgress(phase: finalPhase, detail: finalDetail)
            linuxRestartCompletedCount += 1
            await ActivityLogger.shared.append(event: event, host: host.id, detail: finalDetail)
        }

        let succeeded = linuxRestarts.values.filter { $0.phase == .succeeded }.count
        let offline = linuxRestarts.values.filter { $0.phase == .offline }.count
        let failed = linuxRestarts.values.filter { $0.phase == .failed }.count
        await ActivityLogger.shared.append(
            event: "linux-restart-finished",
            detail: "verified=\(succeeded); offline=\(offline); failed=\(failed)"
        )
        notice = offline == 0 && failed == 0
            ? "Linux restart verified on \(succeeded) machine\(succeeded == 1 ? "" : "s")"
            : "Linux restart: \(succeeded) verified · \(offline) offline · \(failed) failed"
    }


    func updateCodexOnAvailableHosts() async {
        let targets = codexUpdateAvailableHosts
        guard !targets.isEmpty else {
            notice = "No outdated online machines were found"
            return
        }
        await performCodexUpdates(on: targets)
    }

    func updateCodexOnAllHosts() async {
        await performCodexUpdates(on: hosts)
    }

    func retryReadyCodexUpdates() async {
        let targets = codexUpdateRetryReadyHosts
        guard !targets.isEmpty else {
            notice = codexUpdateProblemCount > 0
                ? "Problem machines are still offline — refresh after they reconnect"
                : "No Codex update problems need a retry"
            return
        }
        await performCodexUpdates(on: targets, preservingProgress: true)
    }

    func updateCodex(on host: FleetHost) async {
        await performCodexUpdates(on: [host])
    }

    func updateCodexDesktopAppsOnAllHosts() async {
        await performCodexDesktopAppUpdates(on: codexDesktopAppHosts)
    }

    func updateCodexDesktopAppsOnAvailableHosts() async {
        let targets = codexDesktopAppUpdateAvailableHosts
        guard !targets.isEmpty else {
            notice = "No Codex Mac app updates are available"
            return
        }
        await performCodexDesktopAppUpdates(on: targets)
    }

    func updateCodexDesktopApp(on host: FleetHost) async {
        guard host.supportsCodexDesktopApp else {
            notice = "Codex desktop app updates are not enabled for \(host.displayName)"
            return
        }
        await performCodexDesktopAppUpdates(on: [host])
    }

    private func performCodexDesktopAppUpdates(on targets: [FleetHost]) async {
        guard mobileControlActiveCheckID == nil,
              !isUpdatingCodexDesktopApps,
              !isUpdatingCodex,
              !isUpdatingLinux,
              !isCheckingLinuxUpdates,
              !isRestartingLinux else { return }
        guard !targets.isEmpty else {
            notice = "No macOS Codex desktop app machines are configured"
            return
        }
        guard !isRefreshing else {
            notice = "Wait for the current fleet check to finish"
            return
        }

        pollTask?.cancel()
        isUpdatingCodexDesktopApps = true
        codexDesktopAppUpdates = Dictionary(uniqueKeysWithValues: targets.map {
            ($0.id, HostCodexUpdateProgress(phase: .notAttempted, detail: "Waiting to check"))
        })
        notice = targets.count == 1
            ? "Checking the Codex app on \(targets[0].displayName)"
            : "Checking and updating the Codex app on \(targets.count) Macs sequentially"

        for host in targets {
            codexDesktopAppUpdates[host.id] = HostCodexUpdateProgress(
                phase: .updating,
                detail: "Checking OpenAI’s updater…"
            )
            let routeAlias = snapshots[host.id]?.routeAlias ?? host.routes.first?.alias
            let result = await Self.runCodexDesktopAppUpdate(host: host, routeAlias: routeAlias)
            let outcome = CodexDesktopAppUpdateParser.outcome(from: result)
            let phase: HostCodexUpdatePhase
            let event: String
            switch outcome.status {
            case .current:
                phase = .succeeded
                event = "codex-app-current"
            case .updated:
                phase = .succeeded
                event = "codex-app-updated"
            case .offline:
                phase = .offline
                event = "codex-app-update-offline"
            case .failed:
                phase = .failed
                event = "codex-app-update-failed"
            }
            codexDesktopAppUpdates[host.id] = HostCodexUpdateProgress(
                phase: phase,
                detail: outcome.detail
            )
            if let version = outcome.activeVersion {
                snapshots[host.id]?.codexDesktopAppVersion = version
            }
            if let build = outcome.activeBuild {
                snapshots[host.id]?.codexDesktopAppBuild = build
            }
            await ActivityLogger.shared.append(event: event, host: host.id, detail: outcome.detail)
        }

        for host in targets where codexDesktopAppUpdates[host.id]?.phase != .offline {
            await refresh(host)
        }
        let verified = codexDesktopAppVerifiedCount
        let problems = codexDesktopAppProblemCount
        isUpdatingCodexDesktopApps = false
        if started { schedulePolling() }
        notice = problems == 0
            ? "Codex app check completed on \(verified) Mac\(verified == 1 ? "" : "s")"
            : "Codex app check: \(verified) verified · \(problems) need attention"
    }

    private func resumeCodexUpdateBatch() async {
        guard let batch = codexUpdateBatch, batch.finishedAt == nil else { return }
        let targets = batch.targetHostIDs.compactMap { hostID in
            hosts.first { $0.id == hostID }
        }
        await performCodexUpdates(on: targets, resuming: true)
    }

    private func performCodexUpdates(
        on targets: [FleetHost],
        resuming: Bool = false,
        preservingProgress: Bool = false
    ) async {
        guard mobileControlActiveCheckID == nil,
              !isUpdatingCodex,
              !isUpdatingCodexDesktopApps,
              !isUpdatingLinux,
              !isCheckingLinuxUpdates,
              !isRestartingLinux else { return }
        guard resuming || !targets.isEmpty else { return }
        guard !isRefreshing else {
            notice = "Wait for the current fleet check to finish"
            return
        }

        pollTask?.cancel()
        isUpdatingCodex = true
        if resuming, let batch = codexUpdateBatch {
            codexUpdateTotalCount = batch.targetHostIDs.count
            codexUpdateCompletedCount = batch.progress.values.filter { $0.phase.isTerminal }.count
            let remaining = max(0, codexUpdateTotalCount - codexUpdateCompletedCount)
            notice = "Resuming Codex update on \(remaining) machine\(remaining == 1 ? "" : "s")"
            await ActivityLogger.shared.append(
                event: "codex-update-resumed",
                detail: "batch=\(batch.id.uuidString); remaining=\(remaining)"
            )
        } else if preservingProgress {
            let knownHostIDs = Set(hosts.map(\.id))
            var retainedHostIDs = (codexUpdateBatch?.targetHostIDs ?? [])
                .filter { knownHostIDs.contains($0) }
            for host in hosts where codexUpdates[host.id] != nil && !retainedHostIDs.contains(host.id) {
                retainedHostIDs.append(host.id)
            }
            for host in targets where !retainedHostIDs.contains(host.id) {
                retainedHostIDs.append(host.id)
            }

            var retainedProgress = Dictionary(uniqueKeysWithValues: retainedHostIDs.compactMap { hostID in
                codexUpdates[hostID].map { (hostID, $0) }
            })
            for host in targets {
                retainedProgress[host.id] = HostCodexUpdateProgress(
                    phase: .notAttempted,
                    detail: "Ready to retry"
                )
            }
            codexUpdates = retainedProgress
            codexUpdateTotalCount = retainedHostIDs.count
            codexUpdateCompletedCount = retainedProgress.values.filter { $0.phase.isTerminal }.count
            codexUpdateBatch = PersistedCodexUpdateBatch(
                targetHostIDs: retainedHostIDs,
                progress: retainedProgress
            )
            persistCodexUpdateBatch()
            notice = targets.count == 1
                ? "Retrying Codex on \(targets[0].displayName)"
                : "Retrying Codex on \(targets.count) reachable machines"
            if let batch = codexUpdateBatch {
                await ActivityLogger.shared.append(
                    event: "codex-update-retry-started",
                    detail: "batch=\(batch.id.uuidString); targets=\(targets.count); retained=\(retainedHostIDs.count)"
                )
            }
        } else {
            codexUpdateCompletedCount = 0
            codexUpdateTotalCount = targets.count
            codexUpdates = Dictionary(uniqueKeysWithValues: targets.map {
                ($0.id, HostCodexUpdateProgress(phase: .notAttempted, detail: "Not attempted yet"))
            })
            codexUpdateBatch = PersistedCodexUpdateBatch(
                targetHostIDs: targets.map(\.id),
                progress: codexUpdates
            )
            persistCodexUpdateBatch()
            notice = targets.count == 1
                ? "Preparing Codex update for \(targets[0].displayName)"
                : "Updating Codex sequentially on \(targets.count) machines"
            if let batch = codexUpdateBatch {
                await ActivityLogger.shared.append(
                    event: "codex-update-started",
                    detail: "batch=\(batch.id.uuidString); targets=\(targets.count)"
                )
            }
        }

        for host in targets {
            guard !(codexUpdates[host.id]?.phase.isTerminal ?? false) else { continue }
            codexUpdates[host.id] = HostCodexUpdateProgress(
                phase: .updating,
                detail: "Updating Codex…"
            )
            persistCodexUpdateBatch()
            let routeAlias = snapshots[host.id]?.routeAlias ?? host.routes.first?.alias
            let result = await Self.runCodexUpdate(host: host, routeAlias: routeAlias)
            let outcome = CodexUpdateParser.outcome(from: result)
            let phase: HostCodexUpdatePhase
            let event: String
            switch outcome.status {
            case .succeeded:
                phase = .succeeded
                event = "codex-update-succeeded"
            case .offline:
                phase = .offline
                event = "codex-update-offline"
            case .failed:
                phase = .failed
                event = "codex-update-failed"
            }
            codexUpdates[host.id] = HostCodexUpdateProgress(
                phase: phase,
                detail: outcome.detail
            )
            codexUpdateCompletedCount += 1
            persistCodexUpdateBatch()
            await ActivityLogger.shared.append(
                event: event,
                host: host.id,
                detail: outcome.detail
            )
        }

        if var batch = codexUpdateBatch {
            batch.finishedAt = Date()
            batch.progress = codexUpdates
            codexUpdateBatch = batch
            persistCodexUpdateBatch()
        }

        let succeeded = codexUpdates.values.filter { $0.phase == .succeeded }.count
        let offline = codexUpdates.values.filter { $0.phase == .offline }.count
        let failed = codexUpdates.values.filter { $0.phase == .failed }.count
        let notAttempted = codexUpdates.values.filter { !$0.phase.isTerminal }.count
        await ActivityLogger.shared.append(
            event: "codex-update-finished",
            detail: "verified=\(succeeded); offline=\(offline); failed=\(failed); not-attempted=\(notAttempted)"
        )

        if targets.count == 1, let host = targets.first {
            await refresh(host)
        } else {
            await refreshAll()
        }

        isUpdatingCodex = false
        if started { schedulePolling() }
        notice = offline == 0 && failed == 0 && notAttempted == 0
            ? "Codex update verified on \(succeeded) machine\(succeeded == 1 ? "" : "s")"
            : codexUpdateSummary(
                succeeded: succeeded,
                offline: offline,
                failed: failed,
                notAttempted: notAttempted
            )
    }

    private func restoreCodexUpdateBatch() {
        guard var batch = CodexUpdateBatchStore.load() else { return }
        let knownHostIDs = Set(hosts.map(\.id))
        for hostID in batch.targetHostIDs {
            if !knownHostIDs.contains(hostID) {
                batch.progress[hostID] = HostCodexUpdateProgress(
                    phase: .failed,
                    detail: "Failed — machine is no longer configured"
                )
            } else if batch.progress[hostID]?.phase == .updating {
                batch.progress[hostID] = HostCodexUpdateProgress(
                    phase: .notAttempted,
                    detail: "Not completed — retrying after restart"
                )
            } else if batch.progress[hostID] == nil {
                batch.progress[hostID] = HostCodexUpdateProgress(
                    phase: .notAttempted,
                    detail: "Not attempted yet"
                )
            }
        }
        codexUpdateBatch = batch
        codexUpdates = batch.progress
        codexUpdateTotalCount = batch.targetHostIDs.count
        codexUpdateCompletedCount = batch.progress.values.filter { $0.phase.isTerminal }.count
        CodexUpdateBatchStore.save(batch)
    }

    private func reconcileCodexUpdateFailuresVerifiedCurrent() async {
        guard !codexUpdates.isEmpty else { return }

        var reconciledUpdates = codexUpdates
        var reconciled: [(hostID: String, detail: String)] = []
        for (hostID, progress) in codexUpdates {
            guard progress.phase == .failed || progress.phase == .offline,
                  let snapshot = snapshots[hostID],
                  let detail = CodexUpdateFailureReconciler.verifiedCurrentDetail(
                    installedVersion: snapshot.codexVersion,
                    latestVersion: latestCodexVersion,
                    isOnline: snapshot.state == .online,
                    releaseCheckFailed: codexReleaseCheckFailed
                  ) else { continue }
            reconciledUpdates[hostID] = HostCodexUpdateProgress(phase: .succeeded, detail: detail)
            reconciled.append((hostID, detail))
        }

        guard !reconciled.isEmpty else { return }
        codexUpdates = reconciledUpdates
        codexUpdateCompletedCount = reconciledUpdates.values.filter { $0.phase.isTerminal }.count
        persistCodexUpdateBatch()
        for result in reconciled {
            await ActivityLogger.shared.append(
                event: "codex-update-failure-reconciled",
                host: result.hostID,
                detail: result.detail
            )
        }
    }

    private func persistCodexUpdateBatch() {
        guard var batch = codexUpdateBatch else { return }
        batch.progress = codexUpdates
        codexUpdateBatch = batch
        CodexUpdateBatchStore.save(batch)
    }

    func clearCodexUpdateResult() async {
        guard !isUpdatingCodex, codexUpdateBatch?.finishedAt != nil else { return }
        codexUpdateBatch = nil
        codexUpdates = [:]
        codexUpdateCompletedCount = 0
        codexUpdateTotalCount = 0
        CodexUpdateBatchStore.clear()
        notice = "Cleared the previous Codex operation result"
        await ActivityLogger.shared.append(event: "codex-update-result-cleared")
    }

    func beginMobileControlPairing() -> MobileControlPairingDisplay {
        mobileControlPairingExpiryTask?.cancel()
        let now = Date()
        let expiresAt = now.addingTimeInterval(2 * 60)
        guard let code = try? MobileControlCrypto.randomPairingCode() else {
            mobileControlPairingChallenge = nil
            let unavailable = MobileControlPairingDisplay(code: "Unavailable", expiresAt: now)
            mobileControlPairingDisplay = unavailable
            notice = "Could not create a secure mobile pairing code"
            return unavailable
        }

        let display = MobileControlPairingDisplay(code: code, expiresAt: expiresAt)
        mobileControlPairingChallenge = MobileControlPairingChallenge(
            codeHash: MobileControlCrypto.hash(code),
            expiresAt: expiresAt,
            failedAttempts: 0
        )
        mobileControlPairingDisplay = display
        mobileControlPairingExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2 * 60))
            guard let self, !Task.isCancelled,
                  self.mobileControlPairingChallenge?.expiresAt == expiresAt else { return }
            self.clearMobileControlPairingChallenge()
        }
        notice = "Mobile pairing code expires in 2 minutes"
        return display
    }

    func revokeMobileControlDevices() {
        do {
            try MobileControlCredentialStore.shared.revokeAll()
            mobileControlPairedDeviceCount = 0
            clearMobileControlPairingChallenge()
            notice = "Revoked all mobile control devices"
            Task { await ActivityLogger.shared.append(event: "mobile-control-devices-revoked") }
        } catch {
            notice = "Could not revoke mobile control devices"
        }
    }

    func setMobileControlCommandAuthorityEnabled(_ enabled: Bool) {
        guard !enabled || mobileControlJobJournalAvailable else {
            notice = "Mobile control is unavailable because its request journal could not be read"
            return
        }
        guard mobileControlCommandAuthorityEnabled != enabled else { return }
        mobileControlCommandAuthorityEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "mobileControlCommandAuthorityEnabled")
        if !enabled { clearMobileControlPairingChallenge() }
        notice = enabled
            ? "This Mac can accept authenticated mobile update commands"
            : "Mobile update commands are disabled on this Mac"
        Task {
            await ActivityLogger.shared.append(
                event: "mobile-control-authority-changed",
                detail: enabled ? "enabled" : "disabled"
            )
        }
    }

    private func clearMobileControlPairingChallenge() {
        mobileControlPairingExpiryTask?.cancel()
        mobileControlPairingExpiryTask = nil
        mobileControlPairingChallenge = nil
        mobileControlPairingDisplay = nil
    }

    private func consumeMobileControlPairingCode(_ candidate: String, now: Date = Date()) throws {
        guard var challenge = mobileControlPairingChallenge else {
            throw MobileControlPairingValidationError.unavailable
        }
        guard now < challenge.expiresAt else {
            clearMobileControlPairingChallenge()
            throw MobileControlPairingValidationError.expired
        }
        guard challenge.failedAttempts < 5 else {
            clearMobileControlPairingChallenge()
            throw MobileControlPairingValidationError.rateLimited
        }

        let matches = MobileControlCrypto.constantTimeEqual(
            MobileControlCrypto.hash(candidate),
            challenge.codeHash
        )
        guard matches else {
            challenge.failedAttempts += 1
            if challenge.failedAttempts >= 5 {
                clearMobileControlPairingChallenge()
                throw MobileControlPairingValidationError.rateLimited
            }
            mobileControlPairingChallenge = challenge
            throw MobileControlPairingValidationError.invalid
        }
        clearMobileControlPairingChallenge()
    }

    private func reconcileInterruptedMobileControlJobs() {
        guard mobileControlJobJournalAvailable else { return }
        var changed = false
        for index in mobileControlJobs.indices where !mobileControlJobs[index].state.isTerminal {
            var job = mobileControlJobs[index]
            job.state = .failed
            job.finishedAt = Date()
            job.progress = job.targetHostIds.map { hostID in
                MobileControlHostProgress(
                    hostId: hostID,
                    phase: "failed",
                    detail: MobileControlInterruption.detail(for: job.action)
                )
            }
            job.completed = job.total
            mobileControlJobs[index] = job
            changed = true
        }
        if changed, !MobileControlJobStore.save(mobileControlJobs) {
            markMobileControlJournalUnavailable()
        }
    }

    private func reconcileInterruptedMobileControlChecks() {
        guard mobileControlJobJournalAvailable else { return }
        var changed = false
        for index in mobileControlChecks.indices where !mobileControlChecks[index].state.isTerminal {
            mobileControlChecks[index].state = .failed
            let detail = "Update check interrupted because the controller restarted"
            failIncompleteReadOnlyUpdateProgress(
                to: &mobileControlChecks[index],
                detail: detail
            )
            mobileControlChecks[index].phase = "complete"
            mobileControlChecks[index].detail = detail
            mobileControlChecks[index].finishedAt = Date()
            changed = true
        }
        if changed {
            mobileControlChecks = MobileControlCheckRetention.retained(mobileControlChecks)
            if !MobileControlCheckStore.save(mobileControlChecks) {
                markMobileControlJournalUnavailable()
            }
        }
    }

    func handleLocalMobilePairingStartRequest(
        _ request: MobileControlHTTPRequest
    ) async -> MobileControlHTTPResponse {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        guard path == "/pairing/start" else {
            return mobileControlError(status: 404, reason: "Not Found", code: "not-found", message: "Route not found")
        }
        guard request.method == "POST" else {
            return mobileControlError(status: 405, reason: "Method Not Allowed", code: "method-not-allowed", message: "POST is required")
        }
        guard mobileControlCommandAuthorityEnabled else {
            return mobileControlError(status: 403, reason: "Forbidden", code: "control-disabled", message: "Mobile command authority is disabled")
        }
        guard UserDefaults.standard.bool(forKey: "mobileControlLocalPairingAdminEnabled") else {
            return mobileControlError(status: 403, reason: "Forbidden", code: "local-pairing-disabled", message: "Local administrative pairing is not armed")
        }
        // This endpoint is an explicit one-shot administrative escape hatch.
        // Consume the opt-in before generating or returning a code.
        UserDefaults.standard.set(false, forKey: "mobileControlLocalPairingAdminEnabled")
        return mobileControlJSONResponse(beginMobileControlPairing(), status: 200, reason: "OK")
    }

    func handleMobileControlHTTPRequest(
        _ request: MobileControlHTTPRequest
    ) async -> MobileControlHTTPResponse {
        let canonicalPath = mobileControlCanonicalPath(request.path)
        guard canonicalPath != nil else {
            return mobileControlError(status: 404, reason: "Not Found", code: "not-found", message: "Route not found")
        }
        guard mobileControlCommandAuthorityEnabled else {
            return mobileControlError(status: 403, reason: "Forbidden", code: "control-disabled", message: "Mobile command authority is disabled")
        }
        guard let path = canonicalPath else {
            return mobileControlError(status: 404, reason: "Not Found", code: "not-found", message: "Route not found")
        }

        if path == "/control/v1/pair" {
            return await handleMobileControlPair(request)
        }

        guard let credential = authenticatedMobileControlCredential(for: request) else {
            return mobileControlError(status: 401, reason: "Unauthorized", code: "invalid-credential", message: "A valid paired-device credential is required")
        }

        switch (request.method, path) {
        case ("GET", "/control/v1/status"):
            return mobileControlJSONResponse(mobileControlStatus(), status: 200, reason: "OK")
        case ("POST", "/control/v1/checks"):
            return await handleMobileControlCheckCreation(request, credential: credential)
        case ("GET", let checkPath) where checkPath.hasPrefix("/control/v1/checks/"):
            let rawID = String(checkPath.dropFirst("/control/v1/checks/".count))
            guard let checkID = UUID(uuidString: rawID),
                  let check = mobileControlChecks.first(where: { $0.id == checkID }) else {
                return mobileControlError(status: 404, reason: "Not Found", code: "check-not-found", message: "Update check not found")
            }
            return mobileControlJSONResponse(mobileControlCheckSnapshot(check), status: 200, reason: "OK")
        case ("POST", "/control/v1/jobs"):
            return await handleMobileControlJobCreation(request, credential: credential)
        case ("GET", let jobPath) where jobPath.hasPrefix("/control/v1/jobs/by-request/"):
            let rawID = String(jobPath.dropFirst("/control/v1/jobs/by-request/".count))
            guard let requestID = UUID(uuidString: rawID),
                  let job = mobileControlJobs.first(where: { $0.requestId == requestID }) else {
                return mobileControlError(status: 404, reason: "Not Found", code: "job-not-found", message: "No job exists for that request ID")
            }
            return mobileControlJSONResponse(mobileControlJobSnapshot(job), status: 200, reason: "OK")
        case ("GET", let jobPath) where jobPath.hasPrefix("/control/v1/jobs/"):
            let rawID = String(jobPath.dropFirst("/control/v1/jobs/".count))
            guard let jobID = UUID(uuidString: rawID),
                  let job = mobileControlJobs.first(where: { $0.id == jobID }) else {
                return mobileControlError(status: 404, reason: "Not Found", code: "job-not-found", message: "Job not found")
            }
            return mobileControlJSONResponse(mobileControlJobSnapshot(job), status: 200, reason: "OK")
        default:
            return mobileControlError(status: 404, reason: "Not Found", code: "not-found", message: "Route not found")
        }
    }

    private func handleMobileControlPair(
        _ request: MobileControlHTTPRequest
    ) async -> MobileControlHTTPResponse {
        guard request.method == "POST" else {
            return mobileControlError(status: 405, reason: "Method Not Allowed", code: "method-not-allowed", message: "POST is required")
        }
        guard let tailscaleLogin = normalizedTailscaleLogin(request.header("Tailscale-User-Login")) else {
            return mobileControlError(status: 403, reason: "Forbidden", code: "identity-missing", message: "A Tailscale user identity is required")
        }
        guard mobileControlRequestHasJSONContentType(request) else {
            return mobileControlError(status: 415, reason: "Unsupported Media Type", code: "json-required", message: "Content-Type must be application/json")
        }

        let decoder = mobileControlJSONDecoder()
        guard let pairRequest = try? decoder.decode(MobileControlPairRequest.self, from: request.body),
              pairRequest.code.count == 8,
              pairRequest.code.allSatisfy(\.isNumber),
              isValidMobileControlDeviceID(pairRequest.deviceId),
              let deviceName = normalizedMobileControlDeviceName(pairRequest.deviceName) else {
            return mobileControlError(status: 400, reason: "Bad Request", code: "invalid-pair-request", message: "Pairing request fields are invalid")
        }

        do {
            try consumeMobileControlPairingCode(pairRequest.code)
        } catch MobileControlPairingValidationError.expired {
            return mobileControlError(status: 410, reason: "Gone", code: "pairing-expired", message: "The pairing code expired")
        } catch MobileControlPairingValidationError.rateLimited {
            return mobileControlError(status: 429, reason: "Too Many Requests", code: "pairing-rate-limited", message: "Too many pairing attempts; create a new code")
        } catch MobileControlPairingValidationError.invalid {
            return mobileControlError(status: 401, reason: "Unauthorized", code: "pairing-invalid", message: "The pairing code is invalid")
        } catch {
            return mobileControlError(status: 410, reason: "Gone", code: "pairing-unavailable", message: "Create a new pairing code on the controller")
        }

        let pairedAt = Date()
        do {
            let token = try MobileControlCredentialStore.shared.issue(
                deviceId: pairRequest.deviceId,
                deviceName: deviceName,
                tailscaleLogin: tailscaleLogin,
                pairedAt: pairedAt
            )
            mobileControlPairedDeviceCount = MobileControlCredentialStore.shared.count()
            await ActivityLogger.shared.append(
                event: "mobile-control-device-paired",
                detail: "device=\(MobileFeedSanitizer.redact(deviceName))"
            )
            return mobileControlJSONResponse(
                MobileControlPairResponse(
                    deviceId: pairRequest.deviceId,
                    token: token,
                    controllerId: mobileControlControllerID,
                    controllerName: FleetObserver.currentDisplayName,
                    pairedAt: pairedAt
                ),
                status: 201,
                reason: "Created"
            )
        } catch {
            return mobileControlError(status: 500, reason: "Internal Server Error", code: "credential-store-failed", message: "Could not save the paired-device credential")
        }
    }

    private func handleMobileControlCheckCreation(
        _ request: MobileControlHTTPRequest,
        credential: MobileControlPairedCredential
    ) async -> MobileControlHTTPResponse {
        guard mobileControlRequestHasJSONContentType(request) else {
            return mobileControlError(status: 415, reason: "Unsupported Media Type", code: "json-required", message: "Content-Type must be application/json")
        }
        guard let checkRequest = try? mobileControlJSONDecoder().decode(MobileControlCheckRequest.self, from: request.body) else {
            return mobileControlError(status: 400, reason: "Bad Request", code: "invalid-check-request", message: "The update-check request is invalid")
        }
        guard let idempotencyKey = request.header("Idempotency-Key"),
              UUID(uuidString: idempotencyKey) == checkRequest.requestId else {
            return mobileControlError(status: 400, reason: "Bad Request", code: "idempotency-key-mismatch", message: "Idempotency-Key must match requestId")
        }

        if let existing = mobileControlChecks.first(where: { $0.requestId == checkRequest.requestId }) {
            return mobileControlJSONResponse(mobileControlCheckSnapshot(existing), status: 200, reason: "OK")
        }
        guard !mobileControlJobs.contains(where: { $0.requestId == checkRequest.requestId }) else {
            return mobileControlError(status: 409, reason: "Conflict", code: "request-id-conflict", message: "That request ID was already used with a different operation")
        }

        guard mobileControlJobJournalAvailable else {
            return mobileControlError(status: 503, reason: "Service Unavailable", code: "job-journal-unavailable", message: "The request journal is unavailable; no update check was started")
        }
        guard mobileControlActiveCheckID == nil,
              mobileControlActiveJobID == nil,
              !isRefreshing,
              !isRefreshQueued,
              refreshingHostIDs.isEmpty,
              !isAnyUpdateOperationRunningExceptMobileControl,
              !isCheckingCodexRelease,
              !isCheckingCodexDesktopAppRelease else {
            return mobileControlError(status: 409, reason: "Conflict", code: "controller-busy", message: "Another fleet operation is already running")
        }

        let check = MobileControlCheck(requestId: checkRequest.requestId)
        var updatedChecks = mobileControlChecks
        updatedChecks.append(check)
        updatedChecks = MobileControlCheckRetention.retained(updatedChecks)
        do {
            try MobileControlCheckStore.saveDurably(updatedChecks)
        } catch {
            markMobileControlJournalUnavailable()
            await ActivityLogger.shared.append(
                event: "mobile-control-check-rejected",
                detail: "reason=journal-write-failed"
            )
            return mobileControlError(status: 503, reason: "Service Unavailable", code: "job-journal-unavailable", message: "The request journal could not be saved; no update check was started")
        }
        mobileControlChecks = updatedChecks
        mobileControlActiveCheckID = check.id
        pollTask?.cancel()
        await ActivityLogger.shared.append(
            event: "mobile-control-check-accepted",
            detail: "check=\(check.id.uuidString); device=\(MobileFeedSanitizer.redact(credential.deviceName))"
        )
        Task { @MainActor [weak self] in
            await self?.runMobileControlCheck(check.id)
        }
        return mobileControlJSONResponse(check, status: 202, reason: "Accepted")
    }

    private func runMobileControlCheck(_ checkID: UUID) async {
        guard mobileControlActiveCheckID == checkID else { return }
        pollTask?.cancel()
        let startedAt = Date()
        let completion = await runReadOnlyUpdateCheck(
            startedAt: startedAt,
            mobileControlCheckID: checkID
        ) { [weak self] phase, detail, completed, changes in
            guard let self, self.mobileControlActiveCheckID == checkID else { return false }
            return self.updateMobileControlCheck(checkID, mutation: { check in
                self.applyReadOnlyUpdateProgress(
                    to: &check,
                    phase: phase,
                    detail: detail,
                    completed: completed,
                    changes: changes,
                    startedAt: check.startedAt == nil ? startedAt : nil
                )
            })
        }
        guard mobileControlActiveCheckID == checkID else { return }
        guard let completion else {
            recoverMobileControlCheckAfterJournalFailure(checkID)
            return
        }
        finishMobileControlCheck(checkID, state: completion.state, detail: completion.detail)
    }

    @discardableResult
    private func updateMobileControlCheck(
        _ checkID: UUID,
        mutation: (inout MobileControlCheck) -> Void
    ) -> Bool {
        guard let index = mobileControlChecks.firstIndex(where: { $0.id == checkID }) else { return false }
        mutation(&mobileControlChecks[index])
        return MobileControlCheckStore.save(mobileControlChecks)
    }

    private func recoverMobileControlCheckAfterJournalFailure(_ checkID: UUID) {
        if let index = mobileControlChecks.firstIndex(where: { $0.id == checkID }) {
            let detail = "Update check stopped because its recovery journal became unavailable"
            mobileControlChecks[index].state = .failed
            failIncompleteReadOnlyUpdateProgress(
                to: &mobileControlChecks[index],
                detail: detail
            )
            mobileControlChecks[index].phase = "complete"
            mobileControlChecks[index].detail = detail
            mobileControlChecks[index].finishedAt = Date()
            mobileControlChecks = MobileControlCheckRetention.retained(mobileControlChecks)
            _ = MobileControlCheckStore.save(mobileControlChecks)
        }
        mobileControlActiveCheckID = nil
        markMobileControlJournalUnavailable()
        resumeRefreshSchedulingAfterMobileControlCheck()
        Task {
            await ActivityLogger.shared.append(
                event: "mobile-control-check-finished",
                detail: "check=\(checkID.uuidString); state=failed; reason=journal-write-failed"
            )
        }
    }

    private func resumeRefreshSchedulingAfterMobileControlCheck() {
        scheduleQueuedRefreshIfNeeded()
        if started { schedulePolling() }
    }

    private func finishMobileControlCheck(
        _ checkID: UUID,
        state: MobileControlJobState,
        detail: String
    ) {
        guard let index = mobileControlChecks.firstIndex(where: { $0.id == checkID }) else {
            mobileControlActiveCheckID = nil
            return
        }
        mobileControlChecks[index].state = state
        mobileControlChecks[index].phase = "complete"
        mobileControlChecks[index].detail = detail
        mobileControlChecks[index].finishedAt = Date()
        mobileControlChecks[index].completed = MobileControlCheckProgressPlan.completedCount(
            mobileControlChecks[index].progress
        )
        mobileControlActiveCheckID = nil
        mobileControlChecks = MobileControlCheckRetention.retained(mobileControlChecks)
        if !MobileControlCheckStore.save(mobileControlChecks) {
            markMobileControlJournalUnavailable()
        }
        resumeRefreshSchedulingAfterMobileControlCheck()
        Task {
            await ActivityLogger.shared.append(
                event: "mobile-control-check-finished",
                detail: "check=\(checkID.uuidString); state=\(state.rawValue)"
            )
        }
    }

    private func mobileControlCheckSnapshot(_ check: MobileControlCheck) -> MobileControlCheck {
        MobileControlCheck(
            id: check.id,
            requestId: check.requestId,
            state: check.state,
            phase: check.phase,
            detail: MobileFeedSanitizer.redact(check.detail),
            startedAt: check.startedAt,
            finishedAt: check.finishedAt,
            completed: check.completed,
            total: check.total,
            progress: check.progress
        )
    }

    private func handleMobileControlJobCreation(
        _ request: MobileControlHTTPRequest,
        credential: MobileControlPairedCredential
    ) async -> MobileControlHTTPResponse {
        guard mobileControlRequestHasJSONContentType(request) else {
            return mobileControlError(status: 415, reason: "Unsupported Media Type", code: "json-required", message: "Content-Type must be application/json")
        }
        guard let jobRequest = try? mobileControlJSONDecoder().decode(MobileControlJobRequest.self, from: request.body) else {
            return mobileControlError(status: 400, reason: "Bad Request", code: "invalid-job-request", message: "The job request is invalid")
        }
        guard let idempotencyKey = request.header("Idempotency-Key"),
              UUID(uuidString: idempotencyKey) == jobRequest.requestId else {
            return mobileControlError(status: 400, reason: "Bad Request", code: "idempotency-key-mismatch", message: "Idempotency-Key must match requestId")
        }

        if let existing = mobileControlJobs.first(where: { $0.requestId == jobRequest.requestId }) {
            guard existing.action == jobRequest.action,
                  existing.targetHostIds == jobRequest.targetHostIds else {
                await ActivityLogger.shared.append(
                    event: "mobile-control-job-rejected",
                    detail: "request=conflicting-replay"
                )
                return mobileControlError(status: 409, reason: "Conflict", code: "request-id-conflict", message: "That request ID was already used with a different operation")
            }
            return mobileControlJSONResponse(mobileControlJobSnapshot(existing), status: 200, reason: "OK")
        }
        guard !mobileControlChecks.contains(where: { $0.requestId == jobRequest.requestId }) else {
            return mobileControlError(status: 409, reason: "Conflict", code: "request-id-conflict", message: "That request ID was already used with a different operation")
        }

        guard mobileControlJobJournalAvailable else {
            return mobileControlError(status: 503, reason: "Service Unavailable", code: "job-journal-unavailable", message: "The request journal is unavailable; no update was started")
        }
        guard mobileControlActiveJobID == nil,
              !isRefreshing,
              !isAnyUpdateOperationRunning,
              !isCheckingCodexRelease,
              !isCheckingCodexDesktopAppRelease else {
            return mobileControlError(status: 409, reason: "Conflict", code: "controller-busy", message: "Another fleet operation is already running")
        }

        let targetResult = mobileControlTargets(for: jobRequest)
        guard case let .success(targets) = targetResult else {
            let detail: String
            if case let .failure(error) = targetResult { detail = error.localizedDescription } else { detail = "Targets are not eligible" }
            await ActivityLogger.shared.append(
                event: "mobile-control-job-rejected",
                detail: "action=\(jobRequest.action.rawValue); targets=\(jobRequest.targetHostIds.count)"
            )
            return mobileControlError(status: 422, reason: "Unprocessable Content", code: "targets-not-eligible", message: detail)
        }

        let job = MobileControlJob(
            requestId: jobRequest.requestId,
            action: jobRequest.action,
            targetHostIds: targets.map(\.id),
            progress: targets.map {
                MobileControlHostProgress(hostId: $0.id, phase: "queued", detail: "Waiting")
            }
        )
        var updatedJobs = mobileControlJobs
        updatedJobs.insert(job, at: 0)
        do {
            try MobileControlJobStore.saveDurably(updatedJobs)
        } catch {
            markMobileControlJournalUnavailable()
            await ActivityLogger.shared.append(
                event: "mobile-control-job-rejected",
                detail: "action=\(job.action.rawValue); reason=journal-write-failed"
            )
            return mobileControlError(status: 503, reason: "Service Unavailable", code: "job-journal-unavailable", message: "The request journal could not be saved; no update was started")
        }
        mobileControlJobs = updatedJobs
        mobileControlActiveJobID = job.id
        await ActivityLogger.shared.append(
            event: "mobile-control-job-accepted",
            detail: "job=\(job.id.uuidString); action=\(job.action.rawValue); targets=\(job.total); device=\(MobileFeedSanitizer.redact(credential.deviceName))"
        )
        Task { @MainActor [weak self] in
            await self?.runMobileControlJob(job.id, targets: targets)
        }
        return mobileControlJSONResponse(job, status: 202, reason: "Accepted")
    }

    private struct MobileControlTargetError: LocalizedError {
        let errorDescription: String?
    }

    private func mobileControlTargets(
        for request: MobileControlJobRequest
    ) -> Result<[FleetHost], MobileControlTargetError> {
        guard MobileControlActionPolicy.acceptsTargetCount(
            action: request.action,
            count: request.targetHostIds.count
        ) else {
            let detail = request.action == .restartLinux
                ? "Choose exactly one Linux machine to restart"
                : "Choose one or more fleet machines"
            return .failure(MobileControlTargetError(errorDescription: detail))
        }
        guard !request.targetHostIds.isEmpty,
              request.targetHostIds.count <= visibleHosts.count,
              Set(request.targetHostIds).count == request.targetHostIds.count else {
            return .failure(MobileControlTargetError(errorDescription: "Choose one or more unique fleet machines"))
        }
        let hostsByID = Dictionary(uniqueKeysWithValues: visibleHosts.map { ($0.id, $0) })
        let targets = request.targetHostIds.compactMap { hostsByID[$0] }
        guard targets.count == request.targetHostIds.count else {
            return .failure(MobileControlTargetError(errorDescription: "One or more machines are not configured"))
        }

        for host in targets {
            let supportsLinuxMaintenance = linuxUpdateHosts.contains(where: { $0.id == host.id })
            let eligible = MobileControlActionPolicy.isEligible(
                action: request.action,
                hostIsOnline: snapshots[host.id]?.state == .online,
                supportsCodexDesktopApp: host.supportsCodexDesktopApp,
                supportsLinuxUpdates: supportsLinuxMaintenance,
                codexCliUpdateAvailable: codexFleetVersionState(for: host) == .updateAvailable,
                codexMacAppUpdateAvailable: codexDesktopAppUpdateAvailableHosts.contains(where: { $0.id == host.id }),
                linuxUpdateAvailable: linuxUpdateHosts.contains(where: { $0.id == host.id })
                    && linuxUpdateSnapshots[host.id]?.state == .updateAvailable,
                restartRequired: linuxUpdateSnapshots[host.id]?.rebootRequired == true
            )
            guard eligible else {
                return .failure(MobileControlTargetError(
                    errorDescription: "\(host.displayName) is not currently eligible for \(request.action.rawValue)"
                ))
            }
        }
        return .success(targets)
    }

    private func runMobileControlJob(_ jobID: UUID, targets: [FleetHost]) async {
        guard let index = mobileControlJobs.firstIndex(where: { $0.id == jobID }),
              mobileControlActiveJobID == jobID else { return }
        mobileControlJobs[index].state = .running
        mobileControlJobs[index].startedAt = Date()
        mobileControlJobs[index].progress = targets.map {
            MobileControlHostProgress(hostId: $0.id, phase: "queued", detail: "Waiting")
        }
        if !MobileControlJobStore.save(mobileControlJobs) { markMobileControlJournalUnavailable() }
        let action = mobileControlJobs[index].action

        let monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.syncMobileControlJobProgress(jobID)
            }
        }

        switch action {
        case .codexCLI:
            await performCodexUpdates(on: targets)
        case .codexMacApp:
            await performCodexDesktopAppUpdates(on: targets)
        case .linuxOS:
            await performLinuxUpdates(on: targets)
        case .restartLinux:
            if let target = targets.first {
                await restartLinuxFromMobileControl(on: target, jobID: jobID)
            }
        }

        monitor.cancel()
        _ = await monitor.result
        finishMobileControlJob(jobID)
    }

    private func restartLinuxFromMobileControl(on host: FleetHost, jobID: UUID) async {
        linuxRestarts[host.id] = HostLinuxRestartProgress(
            phase: .verifying,
            detail: "Verifying live restart requirement…"
        )
        guard snapshots[host.id]?.state == .online else {
            linuxRestarts[host.id] = HostLinuxRestartProgress(
                phase: .offline,
                detail: "Restart not issued — machine is no longer online"
            )
            return
        }

        let routeAlias = snapshots[host.id]?.routeAlias ?? host.routes.first?.alias
        let result = await Self.runLinuxRestartRequirementCheck(host: host, routeAlias: routeAlias)
        let outcome = LinuxRestartRequirementParser.outcome(from: result)
        let checkedAt = Date()

        switch MobileControlLinuxRestartPreflight.decision(for: outcome.status) {
        case .proceed:
            await applyLinuxRestartRequirements([(host.id, true, checkedAt)])
            guard snapshots[host.id]?.state == .online else {
                linuxRestarts[host.id] = HostLinuxRestartProgress(
                    phase: .offline,
                    detail: "Restart not issued — machine went offline during verification"
                )
                return
            }
            linuxRestarts[host.id] = HostLinuxRestartProgress(
                phase: .issuing,
                detail: "Live requirement verified · preparing confirmed restart…"
            )
            syncMobileControlJobProgress(jobID)
            guard mobileControlJobJournalAvailable else {
                linuxRestarts[host.id] = HostLinuxRestartProgress(
                    phase: .failed,
                    detail: "Restart not issued — request journal is unavailable"
                )
                return
            }
            await restartLinux(on: host, mobileControlJobID: jobID)
        case .skipNoLongerRequired:
            await applyLinuxRestartRequirements([(host.id, false, checkedAt)])
            linuxRestarts[host.id] = HostLinuxRestartProgress(
                phase: .succeeded,
                detail: "Restart skipped — live check confirms it is no longer required"
            )
        case .failOffline:
            linuxRestarts[host.id] = HostLinuxRestartProgress(
                phase: .offline,
                detail: "Restart not issued — machine is offline"
            )
        case .failVerification:
            linuxRestarts[host.id] = HostLinuxRestartProgress(
                phase: .failed,
                detail: "Restart not issued — \(outcome.detail)"
            )
        }
    }

    private func syncMobileControlJobProgress(_ jobID: UUID) {
        guard let index = mobileControlJobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = mobileControlJobs[index]
        guard !job.state.isTerminal else { return }
        let progress = job.targetHostIds.map { hostID -> MobileControlHostProgress in
            switch job.action {
            case .codexCLI:
                let value = codexUpdates[hostID]
                return MobileControlProgressMapper.map(hostId: hostID, phase: value?.phase.rawValue, detail: value?.detail)
            case .codexMacApp:
                let value = codexDesktopAppUpdates[hostID]
                return MobileControlProgressMapper.map(hostId: hostID, phase: value?.phase.rawValue, detail: value?.detail)
            case .linuxOS:
                let value = linuxUpdates[hostID]
                return MobileControlProgressMapper.map(hostId: hostID, phase: value?.phase.rawValue, detail: value?.detail)
            case .restartLinux:
                let value = linuxRestarts[hostID]
                return MobileControlProgressMapper.map(hostId: hostID, phase: value?.phase.rawValue, detail: value?.detail)
            }
        }
        let completed = progress.filter(MobileControlProgressMapper.isTerminal).count
        guard progress != mobileControlJobs[index].progress
                || completed != mobileControlJobs[index].completed else { return }
        mobileControlJobs[index].progress = progress
        mobileControlJobs[index].completed = completed
        if !MobileControlJobStore.save(mobileControlJobs) { markMobileControlJournalUnavailable() }
    }

    private func finishMobileControlJob(_ jobID: UUID) {
        syncMobileControlJobProgress(jobID)
        guard let index = mobileControlJobs.firstIndex(where: { $0.id == jobID }) else { return }
        var job = mobileControlJobs[index]
        job.progress = job.progress.map { value in
            guard MobileControlProgressMapper.isTerminal(value) else {
                return MobileControlHostProgress(
                    hostId: value.hostId,
                    phase: "failed",
                    detail: "Operation did not complete"
                )
            }
            return value
        }
        let succeeded = job.progress.filter { $0.phase == "succeeded" }.count
        job.completed = job.total
        job.finishedAt = Date()
        if succeeded == job.total {
            job.state = .succeeded
        } else if succeeded > 0 {
            job.state = .partial
        } else {
            job.state = .failed
        }
        mobileControlJobs[index] = job
        mobileControlActiveJobID = nil
        if !MobileControlJobStore.save(mobileControlJobs) { markMobileControlJournalUnavailable() }
        Task {
            await ActivityLogger.shared.append(
                event: "mobile-control-job-finished",
                detail: "job=\(job.id.uuidString); state=\(job.state.rawValue); completed=\(job.completed)"
            )
        }
    }

    private func mobileControlJobSnapshot(_ job: MobileControlJob) -> MobileControlJob {
        if job.id == mobileControlActiveJobID {
            syncMobileControlJobProgress(job.id)
            return mobileControlJobs.first(where: { $0.id == job.id }) ?? job
        }
        var sanitized = job
        sanitized.progress = job.progress.map {
            MobileControlHostProgress(
                hostId: $0.hostId,
                phase: $0.phase,
                detail: MobileFeedSanitizer.redact($0.detail)
            )
        }
        return sanitized
    }

    private func mobileControlStatus() -> MobileControlStatus {
        if let mobileControlActiveJobID { syncMobileControlJobProgress(mobileControlActiveJobID) }
        let cliAvailable = Set(codexUpdateAvailableHosts.map(\.id))
        let appAvailable = Set(codexDesktopAppUpdateAvailableHosts.map(\.id))
        let linuxAvailable = Set(linuxUpdateAvailableHosts.map(\.id))
        let linuxMaintenanceHosts = Set(linuxUpdateHosts.map(\.id))
        let capabilities = visibleHosts.map { host -> MobileControlHostCapability in
            let snapshot = snapshots[host.id] ?? HostSnapshot()
            let supportsLinuxMaintenance = linuxMaintenanceHosts.contains(host.id)
            let linuxUpdateAvailable = supportsLinuxMaintenance && linuxAvailable.contains(host.id)
            let restartRequired = supportsLinuxMaintenance
                && linuxUpdateSnapshots[host.id]?.rebootRequired == true
            let actions = MobileControlAction.allCases.filter {
                MobileControlActionPolicy.isSupported(
                    action: $0,
                    hostIsOnline: snapshot.state == .online,
                    supportsCodexDesktopApp: host.supportsCodexDesktopApp,
                    supportsLinuxUpdates: supportsLinuxMaintenance
                )
            }
            return MobileControlHostCapability(
                hostId: host.id,
                hostName: host.displayName,
                state: snapshot.state.rawValue,
                actions: actions,
                codexCliUpdateAvailable: cliAvailable.contains(host.id),
                codexMacAppUpdateAvailable: appAvailable.contains(host.id),
                linuxUpdateAvailable: linuxUpdateAvailable,
                restartRequired: restartRequired,
                linuxCheckedAt: linuxUpdateSnapshots[host.id]?.checkedAt
            )
        }
        let recentJobs = Array(mobileControlJobs.sorted { $0.createdAt > $1.createdAt }.prefix(20)).map(mobileControlJobSnapshot)
        return MobileControlStatus(
            controllerId: mobileControlControllerID,
            controllerName: FleetObserver.currentDisplayName,
            appVersion: FleetlightVersion.currentDisplayLabel,
            commandAuthorityEnabled: mobileControlCommandAuthorityEnabled,
            jobJournalAvailable: mobileControlJobJournalAvailable,
            pairedDeviceCount: mobileControlPairedDeviceCount,
            busy: mobileControlActiveJobID != nil
                || mobileControlActiveCheckID != nil
                || isAnyUpdateOperationRunning
                || isRefreshing,
            activeJobId: mobileControlActiveJobID,
            checkingUpdates: mobileControlActiveCheckID != nil,
            activeCheckId: mobileControlActiveCheckID,
            latestCodexCliVersion: latestCodexVersion,
            codexCliCheckedAt: codexReleaseCheckedAt,
            codexCliCheckFailed: codexReleaseCheckFailed,
            latestCodexMacAppVersion: latestCodexDesktopAppRelease?.version,
            latestCodexMacAppBuild: latestCodexDesktopAppRelease?.build,
            codexMacAppCheckedAt: codexDesktopAppReleaseCheckedAt,
            codexMacAppCheckFailed: codexDesktopAppReleaseCheckFailed,
            capabilities: capabilities,
            recentJobs: recentJobs
        )
    }

    private var mobileControlControllerID: String {
        FleetObserver.currentDisplayName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    private func markMobileControlJournalUnavailable() {
        guard mobileControlJobJournalAvailable else { return }
        mobileControlJobJournalAvailable = false
        mobileControlCommandAuthorityEnabled = false
        UserDefaults.standard.set(false, forKey: "mobileControlCommandAuthorityEnabled")
        clearMobileControlPairingChallenge()
        notice = "Mobile control request journal is unavailable; new jobs are disabled"
        Task {
            await ActivityLogger.shared.append(
                event: "mobile-control-journal-failed",
                detail: "New mobile jobs disabled"
            )
        }
    }

    private func authenticatedMobileControlCredential(
        for request: MobileControlHTTPRequest
    ) -> MobileControlPairedCredential? {
        guard let login = normalizedTailscaleLogin(request.header("Tailscale-User-Login")),
              let credential = MobileControlCredentialStore.shared.authenticate(
                authorizationHeader: request.header("Authorization")
              ),
              credential.tailscaleLogin.caseInsensitiveCompare(login) == .orderedSame else { return nil }
        return credential
    }

    private func normalizedTailscaleLogin(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty,
              normalized.utf8.count <= 320,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return normalized
    }

    private func normalizedMobileControlDeviceName(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 80,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return normalized
    }

    private func isValidMobileControlDeviceID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil
    }

    private func mobileControlRequestHasJSONContentType(_ request: MobileControlHTTPRequest) -> Bool {
        request.header("Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "application/json"
    }

    private func mobileControlCanonicalPath(_ rawPath: String) -> String? {
        guard !rawPath.contains("?") else { return nil }
        let path = rawPath
        if path == "/control/v1" || path.hasPrefix("/control/v1/") { return path }
        if path == "/fleetlight/control/v1" { return "/control/v1" }
        if path.hasPrefix("/fleetlight/control/v1/") {
            return String(path.dropFirst("/fleetlight".count))
        }
        return nil
    }

    private func mobileControlJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func mobileControlJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func mobileControlJSONResponse<Value: Encodable>(
        _ value: Value,
        status: Int,
        reason: String
    ) -> MobileControlHTTPResponse {
        guard let data = try? mobileControlJSONEncoder().encode(value) else {
            return MobileControlHTTPResponse(
                statusCode: 500,
                reason: "Internal Server Error",
                body: Data(#"{"schemaVersion":1,"error":{"code":"encoding-failed","message":"Response encoding failed"}}"#.utf8)
            )
        }
        return MobileControlHTTPResponse(statusCode: status, reason: reason, body: data)
    }

    private func mobileControlError(
        status: Int,
        reason: String,
        code: String,
        message: String
    ) -> MobileControlHTTPResponse {
        mobileControlJSONResponse(
            MobileControlAPIErrorBody(code: code, message: MobileFeedSanitizer.redact(message)),
            status: status,
            reason: reason
        )
    }

    private func codexUpdateSummary(
        succeeded: Int,
        offline: Int,
        failed: Int,
        notAttempted: Int
    ) -> String {
        var parts = ["\(succeeded) verified"]
        if offline > 0 { parts.append("\(offline) offline") }
        if failed > 0 { parts.append("\(failed) failed") }
        if notAttempted > 0 { parts.append("\(notAttempted) not attempted") }
        return "Codex update: " + parts.joined(separator: " · ")
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        guard [30.0, 60.0, 120.0, 300.0].contains(interval) else { return }
        refreshInterval = interval
        UserDefaults.standard.set(interval, forKey: "refreshInterval")
        notice = "Refresh interval set to \(refreshIntervalLabel)"
        if started { schedulePolling() }
    }

    func setHostVisible(_ host: FleetHost, visible: Bool) {
        if visible {
            hiddenHostIDs.remove(host.id)
        } else {
            guard visibleHosts.count > 1 else {
                notice = "At least one machine must remain visible"
                return
            }
            hiddenHostIDs.insert(host.id)
        }
        UserDefaults.standard.set(Array(hiddenHostIDs).sorted(), forKey: "hiddenHostIDs")
    }

    func isHostVisible(_ host: FleetHost) -> Bool {
        !hiddenHostIDs.contains(host.id)
    }

    func performanceWarnings(for hostID: String) -> [PerformanceWarning] {
        guard let snapshot = snapshots[hostID] else { return [] }
        return PerformanceEvaluator.warnings(snapshot: snapshot, thresholds: performanceThresholds)
    }

    func needsAttention(_ host: FleetHost) -> Bool {
        guard let snapshot = snapshots[host.id] else { return false }
        return snapshot.needsAttention || !performanceWarnings(for: host.id).isEmpty
    }

    func setPerformanceThresholds(_ thresholds: PerformanceThresholds) {
        performanceThresholds = PerformanceThresholds(
            pingWarningMilliseconds: min(1_000, max(25, thresholds.pingWarningMilliseconds)),
            jitterWarningMilliseconds: min(500, max(5, thresholds.jitterWarningMilliseconds)),
            packetLossWarningPercent: min(100, max(0.1, thresholds.packetLossWarningPercent)),
            connectionReadyWarningMilliseconds: min(10_000, max(250, thresholds.connectionReadyWarningMilliseconds)),
            fullProbeWarningMilliseconds: min(20_000, max(500, thresholds.fullProbeWarningMilliseconds))
        )
        if let data = try? JSONEncoder().encode(performanceThresholds) {
            UserDefaults.standard.set(data, forKey: "performanceThresholds")
        }
        performanceFailureCounts.removeAll()
        notice = "Performance warning thresholds updated"
    }

    func resetPerformanceThresholds() {
        setPerformanceThresholds(.default)
        notice = "Performance warning thresholds reset"
    }

    func setFleetStatusFilter(_ filter: FleetStatusFilter) {
        fleetStatusFilter = fleetStatusFilter == filter ? .all : filter
        UserDefaults.standard.set(fleetStatusFilter.rawValue, forKey: "fleetStatusFilter")
        UserDefaults.standard.set(fleetStatusFilter == .attention, forKey: "attentionOnly")
    }

    func setFleetSortMode(_ mode: FleetSortMode) {
        fleetSortMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "fleetSortMode")
        notice = "Sorted by \(mode.displayName.lowercased())"
    }

    func togglePinned(_ host: FleetHost) {
        if pinnedHostIDs.contains(host.id) {
            pinnedHostIDs.remove(host.id)
            notice = "\(host.displayName) unpinned"
        } else {
            pinnedHostIDs.insert(host.id)
            notice = "\(host.displayName) pinned to the top"
        }
        UserDefaults.standard.set(Array(pinnedHostIDs).sorted(), forKey: "pinnedHostIDs")
    }

    func samples(for hostID: String, hours: Double = 24) -> [MetricSample] {
        let key = HistoryWindowCacheKey(hostID: hostID, hours: hours)
        if let cached = historyWindowCache[key] { return cached }
        let result = HistoryAnalyzer.recentSortedSamples(
            historySamplesByHost[hostID] ?? [],
            hours: hours,
            now: lastRefresh ?? Date()
        )
        historyWindowCache[key] = result
        return result
    }

    func chartSamples(for hostID: String, hours: Double, maxPoints: Int = 600) -> [MetricSample] {
        let key = TrendSampleCacheKey(hostID: hostID, hours: hours, maxPoints: maxPoints)
        if let cached = trendSampleCache[key] { return cached }
        let result = TrendSampleDownsampler.downsample(
            samples(for: hostID, hours: hours),
            maxPoints: maxPoints
        )
        trendSampleCache[key] = result
        return result
    }

    func historySummary(for hostID: String, hours: Double = 24) -> HistorySummary {
        let key = HistoryWindowCacheKey(hostID: hostID, hours: hours)
        if let cached = historySummaryCache[key] { return cached }
        let result = HistoryAnalyzer.summary(samples: samples(for: hostID, hours: hours))
        historySummaryCache[key] = result
        return result
    }

    private func mergeHistoryIndex(_ loadedIndex: [String: [MetricSample]]) {
        var merged = loadedIndex
        for (hostID, liveSamples) in historySamplesByHost where !liveSamples.isEmpty {
            var hostSamples = merged[hostID, default: []]
            var knownIDs = Set(hostSamples.map(\.id))
            hostSamples.append(contentsOf: liveSamples.filter { knownIDs.insert($0.id).inserted })
            if !zip(hostSamples, hostSamples.dropFirst()).allSatisfy({ pair in
                pair.0.timestamp <= pair.1.timestamp
            }) {
                hostSamples.sort {
                    $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp
                }
            }
            merged[hostID] = hostSamples
        }
        historySamplesByHost = merged
        nextHistoryPruneAt = Date().addingTimeInterval(15 * 60)
        invalidateHistoryCaches()
        historyRevision &+= 1
    }

    private func appendHistoryBatch(_ batch: [MetricSample], now: Date = Date()) {
        guard !batch.isEmpty else { return }
        for sample in batch {
            let preservesHostOrder = historySamplesByHost[sample.hostID]?.last.map {
                $0.timestamp <= sample.timestamp
            } ?? true
            historySamplesByHost[sample.hostID, default: []].append(sample)
            if !preservesHostOrder {
                historySamplesByHost[sample.hostID]?.sort {
                    $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp
                }
            }
        }

        if now >= nextHistoryPruneAt {
            let cutoff = now.addingTimeInterval(-7 * 24 * 3_600)
            for hostID in Array(historySamplesByHost.keys) {
                historySamplesByHost[hostID]?.removeAll { $0.timestamp < cutoff }
            }
            nextHistoryPruneAt = now.addingTimeInterval(15 * 60)
        }
        invalidateHistoryCaches()
        historyRevision &+= 1
    }

    private func invalidateHistoryCaches() {
        historyWindowCache.removeAll(keepingCapacity: true)
        historySummaryCache.removeAll(keepingCapacity: true)
        trendSampleCache.removeAll(keepingCapacity: true)
    }

    func availability(for hostID: String) -> Double? {
        historySummary(for: hostID).availabilityPercent
    }

    func averageConnectionReady(for hostID: String) -> Double? {
        historySummary(for: hostID).averageConnectionReadyMilliseconds
    }

    func averagePing(for hostID: String) -> Double? {
        historySummary(for: hostID).averagePingMilliseconds
    }

    func averagePingJitter(for hostID: String) -> Double? {
        historySummary(for: hostID).averagePingJitterMilliseconds
    }

    func averagePacketLoss(for hostID: String) -> Double? {
        historySummary(for: hostID).averagePacketLossPercent
    }

    func averageProbeDuration(for hostID: String) -> Double? {
        historySummary(for: hostID).averageProbeDurationMilliseconds
    }

    func averageProbeWork(for hostID: String) -> Double? {
        historySummary(for: hostID).averageProbeWorkMilliseconds
    }

    func incidentCount(for hostID: String) -> Int {
        historySummary(for: hostID).incidentCount
    }

    func healthScore(for hostID: String) -> Int {
        guard let snapshot = snapshots[hostID] else { return 0 }
        return HealthScorer.score(
            snapshot: snapshot,
            availability: availability(for: hostID),
            thresholds: performanceThresholds
        )
    }

    func refresh(_ host: FleetHost) async {
        if isLinuxRefreshBlocked {
            await requestRefreshAll()
            return
        }
        guard !isValidatingRoutes, !refreshingHostIDs.contains(host.id) else { return }
        refreshingHostIDs.insert(host.id)
        defer {
            refreshingHostIDs.remove(host.id)
            scheduleQueuedRefreshIfNeeded()
        }

        let previous = snapshots[host.id]
        let snapshot = await Self.probe(host: host)
        snapshots[host.id] = snapshot
        await handleTransitions(host: host, previous: previous, current: snapshot, isInitialRefresh: false)
        if host.supportsLinuxUpdates,
           snapshot.state == .online,
           let rebootRequired = snapshot.linuxRestartRequired {
            await applyLinuxRestartRequirements([(host.id, rebootRequired, snapshot.checkedAt ?? Date())])
        }
        let historyBatch = await MetricHistoryStore.shared.append(snapshots: [host.id: snapshot])
        appendHistoryBatch(historyBatch)
        await logProbe(hostID: host.id, snapshot: snapshot)
        notice = "\(host.displayName) refreshed"
    }

    func testRoutes(for host: FleetHost) async {
        routeTests[host.id] = host.routes.map {
            RouteProbeResult(route: $0, state: .checking, detail: "Checking…")
        }

        let results = await withTaskGroup(of: RouteProbeResult.self, returning: [RouteProbeResult].self) { group in
            for route in host.routes {
                group.addTask {
                    let snapshot = await Self.probe(host: host, route: route, includeServices: false, multiplex: false)
                    return RouteProbeResult(
                        route: route,
                        state: snapshot.state == .online ? .reachable : .unreachable,
                        latencyMilliseconds: snapshot.latencyMilliseconds,
                        detail: snapshot.state == .online ? "Verified" : snapshot.detail,
                        checkedAt: snapshot.checkedAt
                    )
                }
            }

            var collected: [RouteProbeResult] = []
            for await result in group { collected.append(result) }
            return collected.sorted { left, right in
                let leftIndex = host.routes.firstIndex(of: left.route) ?? 0
                let rightIndex = host.routes.firstIndex(of: right.route) ?? 0
                return leftIndex < rightIndex
            }
        }

        routeTests[host.id] = results
        let reachable = results.filter { $0.state == .reachable }.count
        notice = "\(host.displayName): \(reachable)/\(results.count) routes reachable"
        await ActivityLogger.shared.append(
            event: "route-test",
            host: host.id,
            detail: results.map { "\($0.route.alias)=\($0.state.rawValue)" }.joined(separator: ",")
        )
    }

    func exportHistoryCSV() {
        Task {
            let exportSamples = await MetricHistoryStore.shared.recent(hours: 7 * 24)
            presentHistoryExport(samples: exportSamples)
        }
    }

    private func presentHistoryExport(samples: [MetricSample]) {
        let panel = NSSavePanel()
        panel.title = "Export Fleetlight History"
        panel.nameFieldStringValue = "Fleetlight-History-\(Date().formatted(.iso8601.year().month().day())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HistoryCSVBuilder.build(samples: samples).write(to: url, atomically: true, encoding: .utf8)
            notice = "History exported to \(url.lastPathComponent)"
        } catch {
            notice = "Export failed: \(error.localizedDescription)"
        }
    }

    func revealDataFolder() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Fleetlight", isDirectory: true)
        NSWorkspace.shared.open(folder)
    }

    func openFleetConfiguration() {
        do {
            NSWorkspace.shared.open(try FleetConfigurationStore.ensureConfigurationExists())
        } catch {
            notice = "Could not open fleet.json: \(error.localizedDescription)"
        }
    }

    func reloadFleetConfiguration() {
        guard !isRefreshing, !isAnyUpdateOperationRunning else {
            notice = "Wait for the current refresh or maintenance operation before reloading fleet.json"
            return
        }
        do {
            let configuration = try FleetConfigurationStore.load()
            let previousSnapshots = snapshots
            hosts = FleetHost.resolvingLocalHost(in: configuration.hosts)
            snapshots = Dictionary(uniqueKeysWithValues: hosts.map {
                ($0.id, previousSnapshots[$0.id] ?? HostSnapshot())
            })
            hiddenHostIDs.formIntersection(Set(hosts.map(\.id)))
            pinnedHostIDs.formIntersection(Set(hosts.map(\.id)))
            UserDefaults.standard.set(Array(hiddenHostIDs).sorted(), forKey: "hiddenHostIDs")
            UserDefaults.standard.set(Array(pinnedHostIDs).sorted(), forKey: "pinnedHostIDs")
            lastFreshSSHValidationAt = .distantPast
            notice = "Loaded \(hosts.count) machine\(hosts.count == 1 ? "" : "s") from fleet.json"
            if started { Task { await refreshAll() } }
        } catch {
            notice = "fleet.json was not reloaded: \(error.localizedDescription)"
        }
    }

    func wake(_ host: FleetHost) async {
        guard let macAddress = host.wakeMACAddress else { return }
        snapshots[host.id]?.state = .waking
        snapshots[host.id]?.detail = "Sending Wake-on-LAN packet…"
        notice = nil
        await ActivityLogger.shared.append(event: "wake-requested", host: host.id)

        do {
            let broadcastAddress = host.wakeBroadcastAddress ?? "255.255.255.255"
            try await Task.detached {
                try WakeOnLAN.send(macAddress: macAddress, broadcastAddress: broadcastAddress)
            }.value
        } catch {
            let detail = "Wake command failed: \(error.localizedDescription)"
            snapshots[host.id] = HostSnapshot(state: .unreachable, checkedAt: Date(), detail: detail)
            notice = detail
            await ActivityLogger.shared.append(event: "wake-command-failed", host: host.id, detail: detail)
            return
        }

        snapshots[host.id]?.detail = "Packet sent; waiting for verified SSH response…"
        await ActivityLogger.shared.append(
            event: "wake-packet-sent",
            host: host.id,
            detail: "Magic packet sent"
        )

        for _ in 1...15 {
            try? await Task.sleep(for: .seconds(4))
            let verified = await Self.probe(host: host)
            if verified.state == .online {
                snapshots[host.id] = verified
                notice = "\(host.displayName) wake verified"
                await ActivityLogger.shared.append(event: "wake-verified", host: host.id, detail: verified.bootDescription)
                await recordIncident(
                    host: host,
                    kind: .wakeVerified,
                    title: "Wake verified",
                    detail: "Online via \(verified.routeName ?? "the configured route")"
                )
                await postNotification(
                    title: "\(host.displayName) is awake",
                    body: "SSH verified via \(verified.routeName ?? "the configured route")",
                    host: host.id,
                    event: "wake-verified"
                )
                return
            }
        }

        snapshots[host.id] = HostSnapshot(
            state: .unreachable,
            checkedAt: Date(),
            detail: "Wake packet sent, but the machine did not become reachable within 60 seconds"
        )
        notice = "Wake remains unverified"
        await ActivityLogger.shared.append(event: "wake-unverified", host: host.id)
        await recordIncident(
            host: host,
            kind: .wakeUnverified,
            title: "Wake remains unverified",
            detail: "No verified SSH response within 60 seconds"
        )
    }

    func openSSH(_ host: FleetHost) {
        guard !host.isLocal else {
            notice = "This Mac is monitored locally"
            return
        }
        let alias = snapshots[host.id]?.routeAlias ?? host.id
        guard let url = URL(string: "ssh://\(alias)") else { return }
        NSWorkspace.shared.open(url)
        Task { await ActivityLogger.shared.append(event: "ssh-opened", host: host.id, detail: "route=\(alias)") }
    }

    func copyReport() {
        let report = FleetReportBuilder.build(
            hosts: hosts,
            snapshots: snapshots,
            thresholds: performanceThresholds
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        notice = "Full diagnosis copied"
    }

    func copyServiceReport() {
        let entries = FleetServiceAnalyzer.entries(hosts: visibleHosts, snapshots: snapshots)
        let report = FleetServiceReportBuilder.build(entries: entries)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        notice = "Service report copied"
        Task {
            await ActivityLogger.shared.append(
                event: "service-report-copied",
                detail: "services=\(entries.count)"
            )
        }
    }

    func copyCodexDesktopAppReport() {
        let report = CodexDesktopAppReportBuilder.build(
            hosts: codexDesktopAppHosts,
            snapshots: snapshots,
            latestRelease: latestCodexDesktopAppRelease
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        notice = "Codex Mac app report copied"
    }

    func copyComparison(metric: FleetTimingMetric) {
        let ranks = FleetTimingRanker.rank(hosts: visibleHosts, snapshots: snapshots, metric: metric)
        let report = FleetComparisonReportBuilder.build(metric: metric, ranks: ranks)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        notice = "\(metric.displayName) comparison copied"
        Task {
            await ActivityLogger.shared.append(
                event: "comparison-copied",
                detail: "metric=\(metric.rawValue); hosts=\(ranks.count)"
            )
        }
    }

    func copyDiagnostics(for host: FleetHost) {
        let report = FleetReportBuilder.build(
            hosts: [host],
            snapshots: snapshots,
            thresholds: performanceThresholds
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        notice = "\(host.displayName) diagnostics copied"
    }

    func openActivityLog() {
        Task {
            let url = ActivityLogger.shared.logURL
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            notice = launchAtLogin ? "Fleetlight will open at login" : "Launch at login disabled"
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            notice = "Could not change login setting: \(error.localizedDescription)"
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard enabled else {
            notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: "notificationsEnabled")
            notice = "Fleet notifications disabled"
            return
        }

        Task {
            let allowed = await NotificationManager.shared.requestAuthorization()
            notificationsEnabled = allowed
            UserDefaults.standard.set(allowed, forKey: "notificationsEnabled")
            notice = allowed ? "Fleet notifications enabled" : "Notification permission was not granted"
        }
    }

    func setCodexUpdateAlertsEnabled(_ enabled: Bool) {
        guard enabled else {
            codexUpdateAlertsEnabled = false
            UserDefaults.standard.set(false, forKey: "codexUpdateAlertsEnabled")
            notice = "Codex update alerts disabled"
            return
        }

        Task {
            let allowed = await NotificationManager.shared.requestAuthorization()
            codexUpdateAlertsEnabled = allowed
            UserDefaults.standard.set(allowed, forKey: "codexUpdateAlertsEnabled")
            notice = allowed ? "Codex update alerts enabled" : "Notification permission was not granted"
            if allowed {
                await postCodexUpdateAlertsIfNeeded()
            }
        }
    }

    private func probeLogEntry(hostID: String, snapshot: HostSnapshot) -> ActivityLogEntry {
        let services = snapshot.services
            .map { "\($0.kind.rawValue)=\($0.state.rawValue)" }
            .joined(separator: ",")
        let logDetail = [
            snapshot.state.rawValue,
            snapshot.routeName.map { "route=\($0)" },
            snapshot.codexVersion.map { "codex=\($0)" },
            snapshot.pingMilliseconds.map { "ping=\($0)ms" },
            snapshot.pingJitterMilliseconds.map { "jitter=\($0)ms" },
            snapshot.packetLossPercent.map { String(format: "loss=%.1f%%", $0) },
            snapshot.detail,
            services.isEmpty ? nil : "services=\(services)",
        ].compactMap { $0 }.joined(separator: "; ")
        return ActivityLogEntry(event: "probe", host: hostID, detail: logDetail)
    }

    private func logProbe(hostID: String, snapshot: HostSnapshot) async {
        await ActivityLogger.shared.append([probeLogEntry(hostID: hostID, snapshot: snapshot)])
    }

    private func recordIncident(
        host: FleetHost,
        kind: IncidentKind,
        title: String,
        detail: String
    ) async {
        let event = IncidentEvent(
            hostID: host.id,
            kind: kind,
            title: title,
            detail: detail
        )
        incidents = await IncidentStore.shared.append(event)
        activeIncidentState.apply(event)
        activeIncidents = activeIncidentState.activeEvents
        await ActivityLogger.shared.append(
            event: "incident-\(kind.rawValue)",
            host: host.id,
            detail: "\(title): \(detail)"
        )
    }

    private func schedulePolling() {
        guard !isRunningReadOnlyUpdateCheck,
              mobileControlActiveCheckID == nil,
              linuxRefreshDeferralDepth == 0,
              !refreshRequestQueue.isQueued else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let interval = self.refreshInterval
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                guard !self.isRunningReadOnlyUpdateCheck,
                      self.mobileControlActiveCheckID == nil else { continue }
                await self.refreshAll(mobileControlCheckID: nil)
            }
        }
    }

    private func handleTransitions(
        host: FleetHost,
        previous: HostSnapshot?,
        current: HostSnapshot,
        isInitialRefresh: Bool
    ) async {
        let oldFailureCount = failureCounts[host.id, default: 0]

        if current.state == .unreachable {
            let newFailureCount = oldFailureCount + 1
            failureCounts[host.id] = newFailureCount
            if !isInitialRefresh && newFailureCount == 2 {
                let hasAccessIssue = FleetConnectionClassifier.status(for: current) == .accessIssue
                let title = hasAccessIssue
                    ? "\(host.displayName) monitoring access failed"
                    : "\(host.displayName) is unreachable"
                await recordIncident(
                    host: host,
                    kind: .hostDown,
                    title: title,
                    detail: current.detail
                )
                await postNotification(
                    title: title,
                    body: current.detail,
                    host: host.id,
                    event: hasAccessIssue ? "monitoring-access-failed" : "host-unreachable"
                )
            }
            return
        }

        failureCounts[host.id] = 0
        if oldFailureCount >= 2 && current.state == .online {
            let restoredAccess = previous.map {
                FleetConnectionClassifier.status(for: $0) == .accessIssue
            } ?? false
            let title = restoredAccess
                ? "\(host.displayName) monitoring access restored"
                : "\(host.displayName) recovered"
            await recordIncident(
                host: host,
                kind: .hostRecovered,
                title: title,
                detail: "Online via \(current.routeName ?? "the configured route")"
            )
            await postNotification(
                title: title,
                body: "Online via \(current.routeName ?? "the configured route")",
                host: host.id,
                event: restoredAccess ? "monitoring-access-restored" : "host-recovered"
            )
        }

        await handlePerformanceTransitions(host: host, current: current, isInitialRefresh: isInitialRefresh)

        guard !isInitialRefresh, let previous else { return }

        if previous.state == .online,
           current.state == .online,
           previous.routeAlias != nil,
           current.routeAlias != previous.routeAlias {
            await recordIncident(
                host: host,
                kind: .routeChanged,
                title: "Connection route changed",
                detail: "\(previous.routeName ?? "Previous route") → \(current.routeName ?? "Current route")"
            )
        }

        if (previous.diskPercent ?? 0) < 90, let disk = current.diskPercent, disk >= 90 {
            await recordIncident(
                host: host,
                kind: .diskWarning,
                title: "Root disk warning",
                detail: "Disk usage reached \(disk)%"
            )
            await postNotification(
                title: "\(host.displayName) disk warning",
                body: "Root disk is \(disk)% used",
                host: host.id,
                event: "disk-warning"
            )
        }

        for service in current.services {
            guard let oldService = previous.services.first(where: { $0.kind == service.kind }),
                  oldService.state != service.state else { continue }

            if service.state.needsAttention {
                await recordIncident(
                    host: host,
                    kind: .serviceAttention,
                    title: "\(service.kind.displayName) needs attention",
                    detail: service.detail
                )
                await postNotification(
                    title: "\(service.kind.displayName) needs attention",
                    body: "\(host.displayName): \(service.detail)",
                    host: host.id,
                    event: "service-\(service.kind.rawValue)-attention"
                )
            } else if oldService.state.needsAttention {
                await recordIncident(
                    host: host,
                    kind: .serviceRecovered,
                    title: "\(service.kind.displayName) recovered",
                    detail: service.detail
                )
                await postNotification(
                    title: "\(service.kind.displayName) recovered",
                    body: "\(host.displayName): \(service.detail)",
                    host: host.id,
                    event: "service-\(service.kind.rawValue)-recovered"
                )
            }
        }
    }

    private func handlePerformanceTransitions(
        host: FleetHost,
        current: HostSnapshot,
        isInitialRefresh: Bool
    ) async {
        let previousCount = performanceFailureCounts[host.id, default: 0]
        let warnings = PerformanceEvaluator.warnings(
            snapshot: current,
            thresholds: performanceThresholds
        )
        let decision = PerformanceIncidentTracker.evaluate(
            previousCount: previousCount,
            hasWarnings: !warnings.isEmpty
        )
        performanceFailureCounts[host.id] = decision.newConsecutiveCount

        switch decision.transition {
        case .attention:
            if !isInitialRefresh {
                await recordIncident(
                    host: host,
                    kind: .performanceAttention,
                    title: "Performance thresholds exceeded",
                    detail: warnings.map { "\($0.kind.displayName): \($0.detail)" }.joined(separator: " · ")
                )
            }
        case .recovered:
            await recordIncident(
                host: host,
                kind: .performanceRecovered,
                title: "Performance recovered",
                detail: "All configured timing measurements are back below their warning thresholds."
            )
        case .none:
            break
        }
    }

    private func postNotification(title: String, body: String, host: String, event: String) async {
        guard notificationsEnabled else { return }
        let identifier = "\(host)-\(event)-\(Int(Date().timeIntervalSince1970))"
        await NotificationManager.shared.send(title: title, body: body, identifier: identifier)
        await ActivityLogger.shared.append(event: "notification-sent", host: host, detail: "\(title): \(body)")
    }

    private func postCodexUpdateAlertsIfNeeded() async {
        guard codexUpdateAlertsEnabled else { return }
        let defaults = UserDefaults.standard

        if let alert = CodexUpdateAlertPlanner.cliAlert(
            latestVersion: latestCodexVersion,
            updateCount: codexReleaseCheckFailed ? 0 : codexUpdateAvailableCount,
            lastNotifiedVersion: defaults.string(forKey: "lastNotifiedCodexVersion")
        ) {
            await NotificationManager.shared.send(
                title: alert.title,
                body: alert.body,
                identifier: alert.identifier
            )
            defaults.set(alert.releaseKey, forKey: "lastNotifiedCodexVersion")
            await ActivityLogger.shared.append(event: "codex-update-alert", host: "fleet", detail: alert.body)
        }

        if let alert = CodexUpdateAlertPlanner.desktopAppAlert(
            latestRelease: latestCodexDesktopAppRelease,
            updateCount: codexDesktopAppReleaseCheckFailed ? 0 : codexDesktopAppReleaseSummary.updateAvailableCount,
            lastNotifiedBuild: defaults.string(forKey: "lastNotifiedCodexDesktopAppBuild")
        ) {
            await NotificationManager.shared.send(
                title: alert.title,
                body: alert.body,
                identifier: alert.identifier
            )
            defaults.set(alert.releaseKey, forKey: "lastNotifiedCodexDesktopAppBuild")
            await ActivityLogger.shared.append(event: "codex-update-alert", host: "fleet", detail: alert.body)
        }
    }

    nonisolated private static func elapsedMilliseconds(since startedAt: UInt64) -> Int {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        return Int(elapsed / 1_000_000)
    }

    nonisolated private static func fetchLatestCodexRelease(bypassCaches: Bool = false) async -> String? {
        guard let url = URL(string: "https://registry.npmjs.org/@openai%2Fcodex/latest") else { return nil }
        let request = MobileControlReleaseRequestPolicy.request(
            url: url,
            accept: "application/json",
            bypassCaches: bypassCaches
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    nonisolated private static func fetchLatestCodexDesktopAppRelease(bypassCaches: Bool = false) async -> String? {
        guard let url = URL(string: "https://persistent.oaistatic.com/codex-app-prod/appcast.xml") else { return nil }
        let request = MobileControlReleaseRequestPolicy.request(
            url: url,
            accept: "application/xml",
            bypassCaches: bypassCaches
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    nonisolated private static func runLinuxUpdateCheck(
        host: FleetHost,
        routeAlias: String?
    ) async -> CommandResult {
        await runLinuxCommand(
            LinuxUpdateCheckCommandBuilder.build(),
            host: host,
            routeAlias: routeAlias,
            timeout: 180,
            multiplex: false
        )
    }

    nonisolated private static func runLinuxUpdateCheckWithRetry(
        host: FleetHost,
        routeAlias: String?
    ) async -> LinuxUpdateSnapshot {
        let firstResult = await runLinuxUpdateCheck(host: host, routeAlias: routeAlias)
        let firstSnapshot = LinuxUpdateCheckParser.snapshot(from: firstResult)
        guard LinuxUpdateCheckRetryPolicy.shouldRetry(
            state: firstSnapshot.state,
            completedRetryCount: 0
        ) else { return firstSnapshot }

        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return firstSnapshot }
        let retryResult = await runLinuxUpdateCheck(host: host, routeAlias: routeAlias)
        return LinuxUpdateCheckParser.snapshot(from: retryResult)
    }

    nonisolated private static func runLinuxUpdateRecoveryCheck(
        host: FleetHost,
        routeAlias: String?
    ) async -> CommandResult {
        await runLinuxCommand(
            LinuxUpdateCheckCommandBuilder.build(refreshMetadata: false),
            host: host,
            routeAlias: routeAlias,
            timeout: 60
        )
    }

    nonisolated private static func runLinuxUpdate(
        host: FleetHost,
        routeAlias: String?
    ) async -> CommandResult {
        await runLinuxCommand(
            LinuxUpdateCommandBuilder.build(),
            host: host,
            routeAlias: routeAlias,
            timeout: 3_600,
            multiplex: false
        )
    }

    nonisolated private static func runLinuxRestart(
        host: FleetHost,
        routeAlias: String?
    ) async -> CommandResult {
        await runLinuxCommand(
            LinuxRestartCommandBuilder.build(),
            host: host,
            routeAlias: routeAlias,
            timeout: 30,
            multiplex: false
        )
    }

    nonisolated private static func runLinuxRestartRequirementCheck(
        host: FleetHost,
        routeAlias: String?
    ) async -> CommandResult {
        await runLinuxCommand(
            LinuxRestartRequirementCommandBuilder.build(),
            host: host,
            routeAlias: routeAlias,
            timeout: 20
        )
    }

    nonisolated private static func runLinuxCommand(
        _ command: String,
        host: FleetHost,
        routeAlias: String?,
        timeout: TimeInterval,
        multiplex: Bool = true
    ) async -> CommandResult {
        if host.isLocal {
            return await CommandRunner.runAsync(
                executable: "/bin/sh",
                arguments: ["-c", command],
                timeout: timeout
            )
        }
        guard let routeAlias else {
            return CommandResult(
                exitCode: -1,
                stdout: "",
                stderr: "No SSH route configured",
                elapsedMilliseconds: 0,
                timedOut: false
            )
        }
        return await CommandRunner.runAsync(
            executable: "/usr/bin/ssh",
            arguments: SSHCommandArguments.build(
                routeAlias: routeAlias,
                command: command,
                connectTimeout: 12,
                serverAliveInterval: 15,
                serverAliveCountMax: 2,
                multiplex: multiplex
            ),
            timeout: timeout
        )
    }

    nonisolated private static func runObserverStatusCheck(
        host: FleetHost,
        routeAlias: String?
    ) async -> CommandResult {
        let command = ObserverStatusCommandBuilder.build()
        if host.isLocal {
            return await CommandRunner.runAsync(
                executable: "/bin/sh",
                arguments: ["-c", command],
                timeout: 10
            )
        }
        guard let routeAlias else {
            return CommandResult(
                exitCode: -1,
                stdout: "",
                stderr: "No SSH route configured",
                elapsedMilliseconds: 0,
                timedOut: false
            )
        }
        return await CommandRunner.runAsync(
            executable: "/usr/bin/ssh",
            arguments: SSHCommandArguments.build(
                routeAlias: routeAlias,
                command: command,
                connectTimeout: 5,
                serverAliveInterval: 15,
                serverAliveCountMax: 2
            ),
            timeout: 10
        )
    }

    nonisolated private static func runCodexUpdate(
        host: FleetHost,
        routeAlias: String?
    ) async -> CommandResult {
        let command = CodexUpdateCommandBuilder.build()
        if host.isLocal {
            return await CommandRunner.runAsync(
                executable: "/bin/sh",
                arguments: ["-c", command],
                timeout: 300
            )
        }
        guard let routeAlias else {
            return CommandResult(
                exitCode: -1,
                stdout: "",
                stderr: "No SSH route configured",
                elapsedMilliseconds: 0,
                timedOut: false
            )
        }
        return await CommandRunner.runAsync(
            executable: "/usr/bin/ssh",
            arguments: SSHCommandArguments.build(
                routeAlias: routeAlias,
                command: command,
                connectTimeout: 12,
                serverAliveInterval: 15,
                serverAliveCountMax: 2,
                multiplex: false
            ),
            timeout: 300
        )
    }

    nonisolated private static func runCodexDesktopAppUpdate(
        host: FleetHost,
        routeAlias: String?
    ) async -> CommandResult {
        let command = CodexDesktopAppUpdateCommandBuilder.build()
        if host.isLocal {
            return await CommandRunner.runAsync(
                executable: "/bin/sh",
                arguments: ["-c", command],
                timeout: 420
            )
        }
        guard let routeAlias else {
            return CommandResult(
                exitCode: -1,
                stdout: "",
                stderr: "No SSH route configured",
                elapsedMilliseconds: 0,
                timedOut: false
            )
        }
        return await CommandRunner.runAsync(
            executable: "/usr/bin/ssh",
            arguments: SSHCommandArguments.build(
                routeAlias: routeAlias,
                command: command,
                connectTimeout: 12,
                serverAliveInterval: 15,
                serverAliveCountMax: 2,
                multiplex: false
            ),
            timeout: 420
        )
    }

    nonisolated private static func probe(host: FleetHost, multiplex: Bool = true) async -> HostSnapshot {
        async let routeProbe = probeRoutes(host: host, multiplex: multiplex)
        async let pingProbe = measurePing(host: host)
        var snapshot = await routeProbe
        if let ping = await pingProbe {
            snapshot.pingMilliseconds = ping.averageMilliseconds
            snapshot.pingMinimumMilliseconds = ping.minimumMilliseconds
            snapshot.pingMaximumMilliseconds = ping.maximumMilliseconds
            snapshot.pingJitterMilliseconds = ping.jitterMilliseconds
            snapshot.packetLossPercent = ping.packetLossPercent
        }
        return snapshot
    }

    nonisolated private static func probeRoutes(
        host: FleetHost,
        includeServices: Bool = true,
        multiplex: Bool = true
    ) async -> HostSnapshot {
        guard let directRoute = host.routes.first else {
            return HostSnapshot(state: .unreachable, checkedAt: Date(), detail: "No SSH route configured")
        }

        let direct = await probe(host: host, route: directRoute, includeServices: includeServices, multiplex: multiplex)
        guard direct.state != .online, host.routes.count > 1 else { return direct }

        let fallbacks = Array(host.routes.dropFirst())
        let recovered = await withTaskGroup(of: HostSnapshot.self, returning: HostSnapshot?.self) { group in
            for route in fallbacks {
                group.addTask {
                    await probe(host: host, route: route, includeServices: includeServices, multiplex: multiplex)
                }
            }

            var firstOnline: HostSnapshot?
            for await candidate in group {
                if candidate.state == .online, firstOnline == nil {
                    firstOnline = candidate
                    group.cancelAll()
                }
            }
            return firstOnline
        }

        if let recovered { return recovered }

        var failed = direct
        failed.routeName = "No working route"
        failed.routeAlias = nil
        failed.detail = "\(direct.detail) · tried \(host.routes.count) routes"
        return failed
    }

    nonisolated private static func measurePing(host: FleetHost) async -> PingMeasurement? {
        guard !host.isLocal, let directRoute = host.routes.first else { return nil }

        let config = await CommandRunner.runBufferedAsync(
            executable: "/usr/bin/ssh",
            arguments: ["-G", directRoute.alias],
            timeout: 2
        )
        let target = SSHConfigParser.hostname(from: config.stdout) ?? directRoute.alias
        let result = await CommandRunner.runBufferedAsync(
            executable: "/sbin/ping",
            arguments: ["-n", "-q", "-c", "3", "-i", "0.2", "-W", "1000", target],
            timeout: 5
        )
        return PingParser.measurement(from: result.stdout)
    }

    nonisolated private static func probe(
        host: FleetHost,
        route: SSHRoute,
        includeServices: Bool = true,
        multiplex: Bool = true
    ) async -> HostSnapshot {
        let remoteCommand = RemoteCommandBuilder.build(services: includeServices ? host.services : [])
        let result: CommandResult
        if host.isLocal {
            result = await CommandRunner.runBufferedAsync(
                executable: "/bin/sh",
                arguments: ["-c", remoteCommand],
                timeout: 10
            )
        } else {
            result = await CommandRunner.runAsync(
                executable: "/usr/bin/ssh",
                arguments: SSHCommandArguments.build(
                    routeAlias: route.alias,
                    command: remoteCommand,
                    connectTimeout: 5,
                    serverAliveInterval: 15,
                    serverAliveCountMax: 2,
                    multiplex: multiplex
                ),
                timeout: 15
            )
        }
        var snapshot = ProbeParser.snapshot(from: result, route: route)
        let serviceOrder = Dictionary(
            host.services.enumerated().map { ($1, $0) },
            uniquingKeysWith: { min($0, $1) }
        )
        snapshot.services.sort {
            serviceOrder[$0.kind, default: Int.max] < serviceOrder[$1.kind, default: Int.max]
        }
        return snapshot
    }
}
