import AppKit
import Foundation
import FleetlightCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class FleetModel: ObservableObject {
    @Published private(set) var snapshots: [String: HostSnapshot]
    @Published private(set) var historySamples: [MetricSample] = []
    @Published private(set) var incidents: [IncidentEvent] = []
    @Published private(set) var activeIncidents: [IncidentEvent] = []
    @Published private(set) var routeTests: [String: [RouteProbeResult]] = [:]
    @Published private(set) var refreshingHostIDs: Set<String> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var hiddenHostIDs: Set<String>
    @Published private(set) var hosts: [FleetHost]
    @Published var refreshInterval: TimeInterval
    @Published var fleetStatusFilter: FleetStatusFilter
    @Published private(set) var pinnedHostIDs: Set<String>
    @Published private(set) var fleetSortMode: FleetSortMode
    @Published var launchAtLogin = false
    @Published var notificationsEnabled: Bool
    @Published private(set) var performanceThresholds: PerformanceThresholds
    @Published var notice: String?

    private var started = false
    private var pollTask: Task<Void, Never>?
    private var failureCounts: [String: Int] = [:]
    private var performanceFailureCounts: [String: Int] = [:]
    private var activeIncidentState = ActiveIncidentState()

    init() {
        let configurationResult = FleetConfigurationStore.loadOrCreate()
        hosts = configurationResult.configuration.hosts
        snapshots = Dictionary(uniqueKeysWithValues: configurationResult.configuration.hosts.map { ($0.id, HostSnapshot()) })
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
        notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        performanceThresholds = UserDefaults.standard.data(forKey: "performanceThresholds")
            .flatMap { try? JSONDecoder().decode(PerformanceThresholds.self, from: $0) }
            ?? .default
        notice = configurationResult.notice
    }

    deinit {
        pollTask?.cancel()
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

    var onlineCount: Int {
        attentionSummary.onlineCount
    }

    var unreachableCount: Int {
        attentionSummary.unreachableCount
    }

    var slowConnectionCount: Int {
        attentionSummary.performanceWarningCount
    }

    var serviceOrResourceAlertCount: Int {
        attentionSummary.serviceOrResourceAlertCount
    }

    var attentionDescription: String {
        var parts: [String] = []
        if unreachableCount > 0 {
            parts.append("\(unreachableCount) can’t connect")
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

    var menuSymbol: String {
        if isRefreshing && lastRefresh == nil { return "network" }
        if attentionCount > 0 { return "exclamationmark.triangle.fill" }
        if visibleHosts.allSatisfy({ snapshots[$0.id]?.state == .online }) { return "circle.grid.2x2.fill" }
        return "circle.grid.2x2"
    }

    func start() async {
        guard !started else { return }
        started = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        async let loadedHistory = MetricHistoryStore.shared.recent(hours: 7 * 24)
        async let loadedIncidents = IncidentStore.shared.recent(limit: 500)
        historySamples = await loadedHistory
        incidents = await loadedIncidents
        activeIncidentState = ActiveIncidentState(events: incidents)
        activeIncidents = activeIncidentState.activeEvents
        for hostID in activeIncidentState.hostDownHostIDs {
            failureCounts[hostID] = 2
        }
        for hostID in activeIncidentState.performanceWarningHostIDs {
            performanceFailureCounts[hostID] = 2
        }
        await refreshAll()
        schedulePolling()
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        notice = nil

        let previousSnapshots = snapshots
        let isInitialRefresh = lastRefresh == nil

        for host in hosts where snapshots[host.id]?.state != .waking {
            snapshots[host.id]?.state = .checking
            snapshots[host.id]?.detail = "Checking SSH, metrics, and services…"
        }

        await withTaskGroup(of: (String, HostSnapshot).self) { group in
            for host in hosts {
                group.addTask {
                    let snapshot = await Self.probe(host: host)
                    return (host.id, snapshot)
                }
            }

            for await (alias, snapshot) in group {
                guard let host = hosts.first(where: { $0.id == alias }) else { continue }
                let previous = previousSnapshots[alias]
                await handleTransitions(
                    host: host,
                    previous: previous,
                    current: snapshot,
                    isInitialRefresh: isInitialRefresh
                )
                snapshots[alias] = snapshot
                await logProbe(hostID: alias, snapshot: snapshot)
            }
        }

        historySamples = await MetricHistoryStore.shared.append(snapshots: snapshots, recentHours: 7 * 24)
        lastRefresh = Date()
        isRefreshing = false
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

    func samples(for hostID: String, hours: Double = 24, now: Date = Date()) -> [MetricSample] {
        HistoryAnalyzer.recentSamples(
            historySamples.filter { $0.hostID == hostID },
            hours: hours,
            now: now
        )
    }

    func availability(for hostID: String) -> Double? {
        HistoryAnalyzer.availabilityPercent(samples: samples(for: hostID))
    }

    func averageConnectionReady(for hostID: String) -> Double? {
        HistoryAnalyzer.averageConnectionReadyMilliseconds(samples: samples(for: hostID))
    }

    func averagePing(for hostID: String) -> Double? {
        HistoryAnalyzer.averagePingMilliseconds(samples: samples(for: hostID))
    }

    func averagePingJitter(for hostID: String) -> Double? {
        HistoryAnalyzer.averagePingJitterMilliseconds(samples: samples(for: hostID))
    }

    func averagePacketLoss(for hostID: String) -> Double? {
        HistoryAnalyzer.averagePacketLossPercent(samples: samples(for: hostID))
    }

    func averageProbeDuration(for hostID: String) -> Double? {
        HistoryAnalyzer.averageProbeDurationMilliseconds(samples: samples(for: hostID))
    }

    func averageProbeWork(for hostID: String) -> Double? {
        HistoryAnalyzer.averageProbeWorkMilliseconds(samples: samples(for: hostID))
    }

    func incidentCount(for hostID: String) -> Int {
        HistoryAnalyzer.incidentCount(samples: samples(for: hostID))
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
        guard !refreshingHostIDs.contains(host.id) else { return }
        refreshingHostIDs.insert(host.id)
        defer { refreshingHostIDs.remove(host.id) }

        let previous = snapshots[host.id]
        let snapshot = await Self.probe(host: host)
        await handleTransitions(host: host, previous: previous, current: snapshot, isInitialRefresh: false)
        snapshots[host.id] = snapshot
        historySamples = await MetricHistoryStore.shared.append(
            snapshots: [host.id: snapshot],
            recentHours: 7 * 24
        )
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
                    let snapshot = await Self.probe(host: host, route: route, includeServices: false)
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
        guard !isRefreshing else {
            notice = "Wait for the current refresh before reloading fleet.json"
            return
        }
        do {
            let configuration = try FleetConfigurationStore.load()
            let previousSnapshots = snapshots
            hosts = configuration.hosts
            snapshots = Dictionary(uniqueKeysWithValues: hosts.map {
                ($0.id, previousSnapshots[$0.id] ?? HostSnapshot())
            })
            hiddenHostIDs.formIntersection(Set(hosts.map(\.id)))
            pinnedHostIDs.formIntersection(Set(hosts.map(\.id)))
            UserDefaults.standard.set(Array(hiddenHostIDs).sorted(), forKey: "hiddenHostIDs")
            UserDefaults.standard.set(Array(pinnedHostIDs).sorted(), forKey: "pinnedHostIDs")
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

    private func logProbe(hostID: String, snapshot: HostSnapshot) async {
        let services = snapshot.services
            .map { "\($0.kind.rawValue)=\($0.state.rawValue)" }
            .joined(separator: ",")
        let logDetail = [
            snapshot.state.rawValue,
            snapshot.routeName.map { "route=\($0)" },
            snapshot.pingMilliseconds.map { "ping=\($0)ms" },
            snapshot.pingJitterMilliseconds.map { "jitter=\($0)ms" },
            snapshot.packetLossPercent.map { String(format: "loss=%.1f%%", $0) },
            snapshot.detail,
            services.isEmpty ? nil : "services=\(services)",
        ].compactMap { $0 }.joined(separator: "; ")
        await ActivityLogger.shared.append(event: "probe", host: hostID, detail: logDetail)
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
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let interval = self.refreshInterval
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self.refreshAll()
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
                await recordIncident(
                    host: host,
                    kind: .hostDown,
                    title: "\(host.displayName) is unreachable",
                    detail: current.detail
                )
                await postNotification(
                    title: "\(host.displayName) is unreachable",
                    body: current.detail,
                    host: host.id,
                    event: "host-unreachable"
                )
            }
            return
        }

        failureCounts[host.id] = 0
        if oldFailureCount >= 2 && current.state == .online {
            await recordIncident(
                host: host,
                kind: .hostRecovered,
                title: "\(host.displayName) recovered",
                detail: "Online via \(current.routeName ?? "the configured route")"
            )
            await postNotification(
                title: "\(host.displayName) recovered",
                body: "Online via \(current.routeName ?? "the configured route")",
                host: host.id,
                event: "host-recovered"
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

    nonisolated private static func probe(host: FleetHost) async -> HostSnapshot {
        var snapshot = await probeRoutes(host: host)
        if let ping = await measurePing(host: host) {
            snapshot.pingMilliseconds = ping.averageMilliseconds
            snapshot.pingMinimumMilliseconds = ping.minimumMilliseconds
            snapshot.pingMaximumMilliseconds = ping.maximumMilliseconds
            snapshot.pingJitterMilliseconds = ping.jitterMilliseconds
            snapshot.packetLossPercent = ping.packetLossPercent
        }
        return snapshot
    }

    nonisolated private static func probeRoutes(host: FleetHost) async -> HostSnapshot {
        guard let directRoute = host.routes.first else {
            return HostSnapshot(state: .unreachable, checkedAt: Date(), detail: "No SSH route configured")
        }

        let direct = await probe(host: host, route: directRoute)
        guard direct.state != .online, host.routes.count > 1 else { return direct }

        let fallbacks = Array(host.routes.dropFirst())
        let recovered = await withTaskGroup(of: HostSnapshot.self, returning: HostSnapshot?.self) { group in
            for route in fallbacks {
                group.addTask { await probe(host: host, route: route) }
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

        return await Task.detached {
            let config = CommandRunner.runBuffered(
                executable: "/usr/bin/ssh",
                arguments: ["-G", directRoute.alias],
                timeout: 2
            )
            let target = SSHConfigParser.hostname(from: config.stdout) ?? directRoute.alias
            let result = CommandRunner.runBuffered(
                executable: "/sbin/ping",
                arguments: ["-n", "-q", "-c", "3", "-i", "0.2", "-W", "1000", target],
                timeout: 5
            )
            return PingParser.measurement(from: result.stdout)
        }.value
    }

    nonisolated private static func probe(
        host: FleetHost,
        route: SSHRoute,
        includeServices: Bool = true
    ) async -> HostSnapshot {
        let remoteCommand = RemoteCommandBuilder.build(services: includeServices ? host.services : [])
        let result = await Task.detached {
            if host.isLocal {
                return CommandRunner.runBuffered(
                    executable: "/bin/sh",
                    arguments: ["-c", remoteCommand],
                    timeout: 10
                )
            }
            return CommandRunner.run(
                    executable: "/usr/bin/ssh",
                    arguments: [
                        "-o", "BatchMode=yes",
                        "-o", "ConnectTimeout=5",
                        "-o", "ConnectionAttempts=1",
                        "-o", "ServerAliveInterval=3",
                        "-o", "ServerAliveCountMax=1",
                        route.alias,
                        remoteCommand,
                    ],
                    timeout: 10
                )
        }.value
        return ProbeParser.snapshot(from: result, route: route)
    }
}
