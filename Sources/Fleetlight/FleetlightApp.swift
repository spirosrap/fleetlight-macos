import Charts
import SwiftUI
import FleetlightCore

@main
struct FleetlightApp: App {
    @StateObject private var model = FleetModel()

    var body: some Scene {
        MenuBarExtra {
            FleetMenuView(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.menuSymbol)
                if let status = model.menuStatusText {
                    Text(status)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .accessibilityLabel("Fleetlight, \(model.attentionDescription)")
            .task { await model.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            FleetSettingsView(model: model)
        }
    }
}

private enum PanelSection: String, CaseIterable, Identifiable {
    case fleet = "Fleet"
    case codex = "Codex"
    case compare = "Compare"
    case trends = "Trends"
    case events = "Events"

    var id: String { rawValue }
}

private enum TrendRange: Double, CaseIterable, Identifiable {
    case oneHour = 1
    case sixHours = 6
    case twentyFourHours = 24
    case sevenDays = 168

    var id: Double { rawValue }
    var hours: Double { rawValue }

    var label: String {
        switch self {
        case .oneHour: "1 hour"
        case .sixHours: "6 hours"
        case .twentyFourHours: "24 hours"
        case .sevenDays: "7 days"
        }
    }

    var compactLabel: String {
        switch self {
        case .oneHour: "1h"
        case .sixHours: "6h"
        case .twentyFourHours: "24h"
        case .sevenDays: "7d"
        }
    }
}

private enum CodexFleetUpdateScope {
    case available
    case all
    case retryReady

    var confirmationButtonTitle: String {
        switch self {
        case .available: "Update Available"
        case .all: "Update All"
        case .retryReady: "Retry Ready"
        }
    }
}

private enum CodexSubview: String, CaseIterable, Identifiable {
    case desktopApp = "Mac App"
    case cli = "CLI"

    var id: String { rawValue }
}

private struct FleetMenuView: View {
    @ObservedObject var model: FleetModel
    @State private var selectedSection: PanelSection = .fleet
    @State private var pendingCodexFleetUpdate: CodexFleetUpdateScope?

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("Section", selection: $selectedSection) {
                ForEach(PanelSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch selectedSection {
                case .fleet:
                    fleetContent
                case .codex:
                    CodexView(
                        model: model,
                        onUpdateAvailable: { pendingCodexFleetUpdate = .available }
                    )
                case .compare:
                    CompareView(model: model)
                case .trends:
                    TrendsView(model: model)
                case .events:
                    EventsView(model: model)
                }
            }
            .frame(height: 500)

            Divider()
            footer
        }
        .frame(width: 460)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.gradient)
                Image(systemName: "circle.grid.2x2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Fleetlight")
                    .font(.headline)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await model.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("Refresh all machines")
        }
        .padding(12)
    }

    private var summaryText: String {
        if model.isRefreshing { return "Checking routes, metrics, and services…" }
        if model.attentionCount > 0 {
            return model.attentionDescription
        }
        if let lastRefresh = model.lastRefresh {
            return "All clear · checked \(lastRefresh.formatted(date: .omitted, time: .shortened))"
        }
        return "Waiting for first check"
    }

    private var fleetContent: some View {
        VStack(spacing: 0) {
            FleetSummaryBar(model: model)
            Divider()

            if model.displayedHosts.isEmpty {
                ContentUnavailableView(
                    emptyFilterTitle,
                    systemImage: emptyFilterSystemImage,
                    description: Text(emptyFilterDescription)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.displayedHosts) { host in
                            HostRow(
                                host: host,
                                snapshot: model.snapshots[host.id] ?? HostSnapshot(),
                                availability: model.availability(for: host.id),
                                healthScore: model.healthScore(for: host.id),
                                performanceWarnings: model.performanceWarnings(for: host.id),
                                routeTests: model.routeTests[host.id] ?? [],
                                isRefreshing: model.refreshingHostIDs.contains(host.id),
                                isPinned: model.pinnedHostIDs.contains(host.id),
                                codexUpdate: model.codexUpdates[host.id],
                                latestCodexVersion: model.latestCodexVersion,
                                isCodexUpdateBusy: model.isUpdatingCodex,
                                onTogglePin: { model.togglePinned(host) },
                                onWake: { Task { await model.wake(host) } },
                                onSSH: { model.openSSH(host) },
                                onCopy: { model.copyDiagnostics(for: host) },
                                onRefresh: { Task { await model.refresh(host) } },
                                onUpdateCodex: { Task { await model.updateCodex(on: host) } },
                                onTestRoutes: { Task { await model.testRoutes(for: host) } }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var emptyFilterTitle: String {
        switch model.fleetStatusFilter {
        case .all: "No visible machines"
        case .online: "No online machines"
        case .offline: "No offline machines"
        case .slow: "No slow connections"
        case .alerts: "No service or resource alerts"
        case .attention: "No machines need attention"
        }
    }

    private var emptyFilterSystemImage: String {
        switch model.fleetStatusFilter {
        case .all: "eye.slash"
        case .online: "network.slash"
        case .offline, .slow, .alerts, .attention: "checkmark.circle"
        }
    }

    private var emptyFilterDescription: String {
        switch model.fleetStatusFilter {
        case .all: "Choose visible machines in Settings."
        case .online: "No visible machine has completed a successful check."
        case .offline: "Every visible machine is currently reachable."
        case .slow: "Every connected machine is below the configured performance thresholds."
        case .alerts: "No connected machine has a service or resource warning."
        case .attention: "Your visible fleet is currently clear."
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let pendingCodexFleetUpdate {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(.blue)
                    Text(codexUpdateConfirmationText(for: pendingCodexFleetUpdate))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Cancel") { self.pendingCodexFleetUpdate = nil }
                    Button(pendingCodexFleetUpdate.confirmationButtonTitle) {
                        confirmCodexUpdate(pendingCodexFleetUpdate)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if let codexReleaseSummary = model.codexReleaseSummary {
                Label(
                    codexReleaseSummary,
                    systemImage: model.isCheckingCodexRelease
                        ? "arrow.triangle.2.circlepath"
                        : model.codexUpdateAvailableCount > 0
                            ? "arrow.up.circle.fill"
                            : model.codexReleaseCheckFailed
                                ? "exclamationmark.triangle"
                                : "checkmark.circle"
                )
                .font(.caption2.weight(model.codexUpdateAvailableCount > 0 ? .semibold : .regular))
                .foregroundStyle(
                    model.codexUpdateAvailableCount > 0
                        ? Color.blue
                        : model.codexReleaseCheckFailed
                            ? Color.orange
                            : Color.secondary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let codexUpdateOutcomeSummary = model.codexUpdateOutcomeSummary,
               !model.isUpdatingCodex {
                HStack(spacing: 8) {
                    Label(
                        codexUpdateOutcomeSummary,
                        systemImage: model.codexUpdateFailedCount > 0
                            ? "exclamationmark.octagon.fill"
                            : model.codexUpdateOfflineCount > 0
                                ? "wifi.slash"
                                : "checkmark.circle.fill"
                    )
                    .font(.caption2.weight(model.codexUpdateProblemCount > 0 ? .semibold : .regular))
                    .foregroundStyle(
                        model.codexUpdateFailedCount > 0
                            ? Color.red
                            : model.codexUpdateOfflineCount > 0
                                ? Color.orange
                                : Color.green
                    )
                    .lineLimit(1)
                    .help("Offline means Fleetlight could not connect. Failed means the updater ran but the new version was not verified.")

                    Spacer(minLength: 4)

                    if model.codexUpdateRetryReadyCount > 0 {
                        Button("Retry \(model.codexUpdateRetryReadyCount) Ready") {
                            pendingCodexFleetUpdate = .retryReady
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else if model.codexUpdateProblemCount > 0 {
                        Button("Check Again") {
                            Task { await model.refreshAll() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isRefreshing)
                        .help("Refresh reachability so reconnected machines become retryable")
                    }
                }
            }

            HStack {
                Button {
                    if model.codexUpdateAvailableCount > 0 {
                        pendingCodexFleetUpdate = .available
                    } else {
                        Task { await model.checkCodexReleaseNow() }
                    }
                } label: {
                    if model.isUpdatingCodex {
                        Label(
                            "Updating \(model.codexUpdateCompletedCount)/\(model.codexUpdateTotalCount)",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    } else if model.codexUpdateAvailableCount > 0 {
                        Label(
                            "Update \(model.codexUpdateAvailableCount) Available",
                            systemImage: "arrow.up.circle.fill"
                        )
                    } else if model.isCheckingCodexRelease {
                        Label("Checking Latest", systemImage: "arrow.triangle.2.circlepath")
                    } else if model.onlineCodexMachinesAreCurrent {
                        Label("Online Current", systemImage: "checkmark.circle")
                    } else {
                        Label("Check Codex", systemImage: "arrow.clockwise.circle")
                    }
                }
                .disabled(
                    model.isUpdatingCodex
                        || model.isRefreshing
                        || model.isCheckingCodexRelease
                        || model.onlineCodexMachinesAreCurrent
                )
                .help(
                    model.codexUpdateAvailableCount > 0
                        ? "Update and verify only the online machines with an older Codex version"
                        : "Check npm for the latest stable Codex version"
                )
                Menu {
                    Button("Check Latest Now") {
                        Task { await model.checkCodexReleaseNow() }
                    }
                    .disabled(model.isCheckingCodexRelease || model.isRefreshing || model.isUpdatingCodex)
                    if model.codexUpdateAvailableCount > 0 {
                        Divider()
                        Button("Update \(model.codexUpdateAvailableCount) Available") {
                            pendingCodexFleetUpdate = .available
                        }
                        .disabled(model.isRefreshing || model.isUpdatingCodex)
                    }
                    Divider()
                    Button("Update All \(model.hosts.count) Machines") {
                        pendingCodexFleetUpdate = .all
                    }
                    .disabled(model.isRefreshing || model.isUpdatingCodex)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More Codex update options")
                Button("Copy Full Diagnosis") { model.copyReport() }
                Menu("Data") {
                    Button("Export History as CSV…") { model.exportHistoryCSV() }
                    Button("Reveal Fleetlight Data") { model.revealDataFolder() }
                    Divider()
                    Button("Open Activity Log") { model.openActivityLog() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Fleetlight Settings")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)

            HStack {
                Toggle("Notifications", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { model.setNotificationsEnabled($0) }
                ))
                Spacer()
                Text("Refresh: \(model.refreshIntervalLabel)")
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)
        }
        .padding(12)
    }

    private func codexUpdateConfirmationText(for scope: CodexFleetUpdateScope) -> String {
        switch scope {
        case .available:
            return model.codexAvailableUpdateConfirmationText
        case .all:
            return model.codexAllUpdateConfirmationText
        case .retryReady:
            return model.codexRetryConfirmationText
        }
    }

    private func confirmCodexUpdate(_ scope: CodexFleetUpdateScope) {
        pendingCodexFleetUpdate = nil
        Task {
            switch scope {
            case .available:
                await model.updateCodexOnAvailableHosts()
            case .all:
                await model.updateCodexOnAllHosts()
            case .retryReady:
                await model.retryReadyCodexUpdates()
            }
        }
    }
}

private struct FleetSummaryBar: View {
    @ObservedObject var model: FleetModel

    var body: some View {
        HStack(spacing: 7) {
            statusButton(.online, value: model.onlineCount, color: .green)
            statusButton(
                .offline,
                value: model.unreachableCount,
                color: model.unreachableCount > 0 ? .red : .secondary
            )
            statusButton(
                .slow,
                value: model.slowConnectionCount,
                color: model.slowConnectionCount > 0 ? .orange : .secondary
            )
            statusButton(
                .alerts,
                value: model.serviceOrResourceAlertCount,
                color: model.serviceOrResourceAlertCount > 0 ? .orange : .secondary
            )
            Spacer()
            sortMenu
            Button {
                model.setFleetStatusFilter(.attention)
            } label: {
                Label(
                    "All issues",
                    systemImage: model.fleetStatusFilter == .attention
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.fleetStatusFilter == .attention ? Color.orange : Color.secondary)
            .help(model.fleetStatusFilter == .attention ? "Show all visible machines" : "Show every machine with an issue")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(FleetSortMode.allCases) { mode in
                Button {
                    model.setFleetSortMode(mode)
                } label: {
                    Label(
                        mode.displayName,
                        systemImage: model.fleetSortMode == mode ? "checkmark" : mode.systemImage
                    )
                }
            }
        } label: {
            Label("Sort: \(model.fleetSortMode.displayName)", systemImage: "arrow.up.arrow.down.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort machines: \(model.fleetSortMode.displayName)")
    }

    private func statusButton(_ filter: FleetStatusFilter, value: Int, color: Color) -> some View {
        Button {
            model.setFleetStatusFilter(filter)
        } label: {
            SummaryPill(
                label: filter.displayName,
                value: "\(value)",
                color: color,
                isSelected: model.fleetStatusFilter == filter
            )
        }
        .buttonStyle(.plain)
        .help(model.fleetStatusFilter == filter ? "Show all visible machines" : "Show \(filter.displayName.lowercased()) machines")
    }
}

private struct CodexView: View {
    @ObservedObject var model: FleetModel
    let onUpdateAvailable: () -> Void
    @State private var pendingDesktopAppHost: FleetHost?
    @State private var isConfirmingAllDesktopApps = false
    @State private var selectedSubview: CodexSubview = .desktopApp

    var body: some View {
        VStack(spacing: 0) {
            Picker("Codex view", selection: $selectedSubview) {
                Text("Mac App (\(model.codexDesktopAppHosts.count))").tag(CodexSubview.desktopApp)
                Text("CLI (\(model.hosts.count))").tag(CodexSubview.cli)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if selectedSubview == .desktopApp {
                desktopAppContent
            } else {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex CLI")
                        .font(.headline)
                    Text(releaseDetail)
                        .font(.caption)
                        .foregroundStyle(model.codexReleaseCheckFailed ? Color.orange : Color.secondary)
                }

                Spacer()

                Button {
                    Task { await model.checkCodexReleaseNow() }
                } label: {
                    Label(
                        model.isCheckingCodexRelease ? "Checking…" : "Check Latest",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isCheckingCodexRelease || model.isRefreshing || model.isUpdatingCodex || model.isUpdatingCodexDesktopApps)

                if model.codexUpdateAvailableCount > 0 {
                    Button("Update \(model.codexUpdateAvailableCount)", action: onUpdateAvailable)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.isRefreshing || model.isUpdatingCodex || model.isUpdatingCodexDesktopApps)
                }
            }
            .padding(12)

            HStack(spacing: 6) {
                SummaryPill(
                    label: "Current",
                    value: "\(model.codexFleetVersionSummary.currentCount)",
                    color: .green,
                    isSelected: false
                )
                SummaryPill(
                    label: "Updates",
                    value: "\(model.codexFleetVersionSummary.updateAvailableCount)",
                    color: model.codexFleetVersionSummary.updateAvailableCount > 0 ? .blue : .secondary,
                    isSelected: false
                )
                SummaryPill(
                    label: "Offline",
                    value: "\(model.codexFleetVersionSummary.offlineCount)",
                    color: model.codexFleetVersionSummary.offlineCount > 0 ? .red : .secondary,
                    isSelected: false
                )
                SummaryPill(
                    label: "Unknown",
                    value: "\(model.codexFleetVersionSummary.unavailableCount)",
                    color: model.codexFleetVersionSummary.unavailableCount > 0 ? .orange : .secondary,
                    isSelected: false
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.hosts) { host in
                        CodexMachineRow(
                            host: host,
                            snapshot: model.snapshots[host.id] ?? HostSnapshot(),
                            state: model.codexFleetVersionState(for: host),
                            latestVersion: model.latestCodexVersion,
                            updateProgress: model.codexUpdates[host.id],
                            isUpdateBusy: model.isUpdatingCodex || model.isUpdatingCodexDesktopApps,
                            onUpdate: { Task { await model.updateCodex(on: host) } }
                        )
                    }

                }
                .padding(12)
            }
            }
        }
        .confirmationDialog(
            "Check and update the Codex app on \(pendingDesktopAppHost?.displayName ?? "this Mac")?",
            isPresented: Binding(
                get: { pendingDesktopAppHost != nil },
                set: { if !$0 { pendingDesktopAppHost = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let host = pendingDesktopAppHost {
                Button("Check & Update \(host.displayName)") {
                    pendingDesktopAppHost = nil
                    Task { await model.updateCodexDesktopApp(on: host) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDesktopAppHost = nil }
        } message: {
            Text("If OpenAI has an update, Codex will close and reopen automatically. Fleetlight stays open.")
        }
        .confirmationDialog(
            "Check and update Codex on all configured Macs?",
            isPresented: $isConfirmingAllDesktopApps,
            titleVisibility: .visible
        ) {
            Button("Check & Update \(model.codexDesktopAppHosts.count) Macs") {
                Task { await model.updateCodexDesktopAppsOnAllHosts() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each Mac is checked sequentially. Codex restarts only where OpenAI’s updater installs a newer version.")
        }
    }

    private var desktopAppContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Mac app")
                        .font(.headline)
                    Text(desktopAppVersionDetail)
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.78))
                    Text("OpenAI’s updater restarts Codex only when it installs a newer version")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    model.copyCodexDesktopAppReport()
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    isConfirmingAllDesktopApps = true
                } label: {
                    Label(
                        model.isUpdatingCodexDesktopApps ? "Updating…" : "Check & Update All",
                        systemImage: "arrow.down.app"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isRefreshing || model.isUpdatingCodex || model.isUpdatingCodexDesktopApps)
            }
            .padding(12)

            HStack(spacing: 6) {
                SummaryPill(
                    label: "Installed",
                    value: "\(model.codexDesktopAppSummary.installedCount)",
                    color: .green,
                    isSelected: false
                )
                SummaryPill(
                    label: "Verified",
                    value: "\(model.codexDesktopAppVerifiedCount)",
                    color: model.codexDesktopAppVerifiedCount > 0 ? .blue : .secondary,
                    isSelected: false
                )
                SummaryPill(
                    label: "Offline",
                    value: "\(model.codexDesktopAppSummary.offlineCount)",
                    color: model.codexDesktopAppSummary.offlineCount > 0 ? .red : .secondary,
                    isSelected: false
                )
                SummaryPill(
                    label: "Missing",
                    value: "\(model.codexDesktopAppSummary.missingCount)",
                    color: model.codexDesktopAppSummary.missingCount > 0 ? .orange : .secondary,
                    isSelected: false
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.codexDesktopAppHosts) { host in
                        CodexDesktopAppMachineRow(
                            host: host,
                            snapshot: model.snapshots[host.id] ?? HostSnapshot(),
                            updateProgress: model.codexDesktopAppUpdates[host.id],
                            isUpdateBusy: model.isUpdatingCodexDesktopApps || model.isUpdatingCodex,
                            onUpdate: { pendingDesktopAppHost = host }
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private var releaseDetail: String {
        if model.isCheckingCodexRelease {
            return "Checking npm for the latest stable release…"
        }
        if let latestCodexVersion = model.latestCodexVersion {
            return model.codexReleaseCheckFailed
                ? "Last known stable \(latestCodexVersion)"
                : "Latest stable \(latestCodexVersion)"
        }
        return model.codexReleaseCheckFailed
            ? "Latest stable release is temporarily unavailable"
            : "Latest stable release has not been checked yet"
    }

    private var desktopAppVersionDetail: String {
        let installed = model.codexDesktopAppHosts.compactMap { host -> (name: String, version: String)? in
            guard let version = model.snapshots[host.id]?.codexDesktopAppVersion else { return nil }
            let build = model.snapshots[host.id]?.codexDesktopAppBuild.map { " (build \($0))" } ?? ""
            return (host.displayName, "\(version)\(build)")
        }
        guard !installed.isEmpty else { return "Installed app version unavailable until the next successful refresh" }

        let uniqueVersions = Set(installed.map(\.version))
        if installed.count == model.codexDesktopAppHosts.count,
           uniqueVersions.count == 1,
           let version = installed.first?.version {
            return "Version \(version) on \(installed.count) Mac\(installed.count == 1 ? "" : "s")"
        }
        return installed.map { "\($0.name): \($0.version)" }.joined(separator: " · ")
    }
}

private struct CodexDesktopAppMachineRow: View {
    let host: FleetHost
    let snapshot: HostSnapshot
    let updateProgress: HostCodexUpdateProgress?
    let isUpdateBusy: Bool
    let onUpdate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(statusColor.opacity(0.15))
                Image(systemName: host.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(host.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(host.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(versionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let checkedDetail {
                    Label(checkedDetail, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let updateProgress {
                    Label(updateProgress.detail, systemImage: progressImage)
                        .font(.caption2)
                        .foregroundStyle(progressColor)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 5) {
                Label(statusTitle, systemImage: statusImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                if canUpdate {
                    Button("Check & Update", action: onUpdate)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isUpdateBusy)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
        )
    }

    private var canUpdate: Bool {
        snapshot.state == .online && snapshot.codexDesktopAppVersion != nil
    }

    private var checkedDetail: String? {
        guard let checkedAt = snapshot.checkedAt else { return nil }
        return "Checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var versionDetail: String {
        switch snapshot.state {
        case .checking: return "Checking installed app version…"
        case .waking: return "Machine is waking…"
        case .unreachable: return "Could not connect to read the app version"
        case .online:
            guard let version = snapshot.codexDesktopAppVersion else {
                return "Codex desktop app is not installed"
            }
            let build = snapshot.codexDesktopAppBuild.map { " · build \($0)" } ?? ""
            return "Installed \(version)\(build)"
        }
    }

    private var statusTitle: String {
        if let phase = updateProgress?.phase {
            switch phase {
            case .notAttempted: return "Waiting"
            case .updating: return "Checking"
            case .succeeded: return "Verified"
            case .offline: return "Offline"
            case .failed: return "Needs attention"
            }
        }
        switch snapshot.state {
        case .checking: return "Checking"
        case .waking: return "Waking"
        case .unreachable: return "Offline"
        case .online: return snapshot.codexDesktopAppVersion == nil ? "Not installed" : "Ready"
        }
    }

    private var statusImage: String {
        switch updateProgress?.phase {
        case .updating: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .offline: return "wifi.slash"
        case .failed: return "exclamationmark.triangle.fill"
        case .notAttempted, nil:
            if snapshot.state == .unreachable { return "wifi.slash" }
            if snapshot.codexDesktopAppVersion == nil { return "questionmark.circle" }
            return "checkmark.circle"
        }
    }

    private var statusColor: Color {
        switch updateProgress?.phase {
        case .updating: return .blue
        case .succeeded: return .green
        case .offline: return .orange
        case .failed: return .red
        case .notAttempted, nil:
            if snapshot.state == .unreachable { return .red }
            if snapshot.codexDesktopAppVersion == nil { return .orange }
            return .secondary
        }
    }

    private var progressImage: String {
        switch updateProgress?.phase {
        case .notAttempted: "circle"
        case .updating: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .failed: "xmark.octagon.fill"
        case nil: "circle"
        }
    }

    private var progressColor: Color {
        switch updateProgress?.phase {
        case .notAttempted: .secondary
        case .updating: .blue
        case .succeeded: .green
        case .offline: .orange
        case .failed: .red
        case nil: .secondary
        }
    }
}

private struct CodexMachineRow: View {
    let host: FleetHost
    let snapshot: HostSnapshot
    let state: CodexFleetVersionState
    let latestVersion: String?
    let updateProgress: HostCodexUpdateProgress?
    let isUpdateBusy: Bool
    let onUpdate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                Image(systemName: host.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(host.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(host.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(versionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let updateProgress {
                    Label(updateProgress.detail, systemImage: updateProgressImage)
                        .font(.caption2)
                        .foregroundStyle(updateProgressColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 5) {
                Label(statusTitle, systemImage: statusImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                if state == .updateAvailable {
                    Button("Update", action: onUpdate)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isUpdateBusy)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
        )
    }

    private var versionDetail: String {
        switch snapshot.state {
        case .checking:
            return "Checking installed version…"
        case .waking:
            return "Machine is waking…"
        case .unreachable:
            return "Could not connect to read the installed version"
        case .online:
            guard let installedVersion = snapshot.codexVersion else {
                return "Installed version unavailable"
            }
            if installedVersion == "Not installed" {
                return "Codex is not installed"
            }
            if installedVersion == "Unavailable" {
                return "Installed version unavailable"
            }
            if state == .updateAvailable, let latestVersion {
                return "Installed \(installedVersion) · latest \(latestVersion)"
            }
            return "Installed \(installedVersion)"
        }
    }

    private var statusTitle: String {
        switch state {
        case .current:
            return "Current"
        case .updateAvailable:
            return "Update available"
        case .offline:
            return "Offline"
        case .unavailable:
            if snapshot.state == .checking { return "Checking" }
            if snapshot.state == .waking { return "Waking" }
            if snapshot.codexVersion == "Not installed" { return "Not installed" }
            return "Unknown"
        }
    }

    private var statusImage: String {
        switch state {
        case .current: "checkmark.circle.fill"
        case .updateAvailable: "arrow.up.circle.fill"
        case .offline: "wifi.slash"
        case .unavailable: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch state {
        case .current: .green
        case .updateAvailable: .blue
        case .offline: .red
        case .unavailable: .orange
        }
    }

    private var updateProgressImage: String {
        switch updateProgress?.phase {
        case .notAttempted: "circle"
        case .updating: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .failed: "xmark.octagon.fill"
        case nil: "circle"
        }
    }

    private var updateProgressColor: Color {
        switch updateProgress?.phase {
        case .notAttempted: .secondary
        case .updating: .blue
        case .succeeded: .green
        case .offline: .orange
        case .failed: .red
        case nil: .secondary
        }
    }
}

private struct CompareView: View {
    @ObservedObject var model: FleetModel
    @State private var metric: FleetTimingMetric = .ping

    private var ranks: [FleetTimingRank] {
        FleetTimingRanker.rank(hosts: model.visibleHosts, snapshots: model.snapshots, metric: metric)
    }

    private var measuredRanks: [FleetTimingRank] {
        ranks.filter { $0.snapshot.state == .online && $0.valueMilliseconds != nil }
    }

    private var best: FleetTimingRank? { measuredRanks.first }

    private var worst: FleetTimingRank? {
        measuredRanks.max { ($0.valueMilliseconds ?? 0) < ($1.valueMilliseconds ?? 0) }
    }

    private var maximumValue: Int {
        max(1, measuredRanks.compactMap(\.valueMilliseconds).max() ?? 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fleet comparison")
                        .font(.headline)
                    Text("Live values ranked fastest to slowest")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Metric", selection: $metric) {
                    ForEach(FleetTimingMetric.allCases) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
                .frame(width: 165)
                Button {
                    model.copyComparison(metric: metric)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this comparison")
            }
            .padding(12)

            Divider()

            if measuredRanks.isEmpty {
                ContentUnavailableView(
                    "No \(metric.displayName.lowercased()) measurements",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Refresh the fleet to collect comparable live values.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        comparisonSummary

                        ForEach(ranks) { rank in
                            ComparisonRow(
                                rank: rank,
                                metric: metric,
                                position: measuredRanks.firstIndex(where: { $0.id == rank.id }).map { $0 + 1 },
                                bestValue: best?.valueMilliseconds,
                                maximumValue: maximumValue
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var comparisonSummary: some View {
        HStack(spacing: 8) {
            TrendStatCard(
                title: "Fastest",
                value: best?.host.displayName ?? "—",
                systemImage: "hare"
            )
            TrendStatCard(
                title: "Best value",
                value: best?.valueMilliseconds.map(durationLabel) ?? "—",
                systemImage: "timer"
            )
            TrendStatCard(
                title: "Spread",
                value: spreadLabel,
                systemImage: "arrow.left.and.right"
            )
        }
    }

    private var spreadLabel: String {
        guard let bestValue = best?.valueMilliseconds,
              let worstValue = worst?.valueMilliseconds else { return "—" }
        return durationLabel(max(0, worstValue - bestValue))
    }

    private func durationLabel(_ milliseconds: Int) -> String {
        if milliseconds >= 1_000 {
            return String(format: "%.2f s", Double(milliseconds) / 1_000)
        }
        return "\(milliseconds) ms"
    }
}

private struct ComparisonRow: View {
    let rank: FleetTimingRank
    let metric: FleetTimingMetric
    let position: Int?
    let bestValue: Int?
    let maximumValue: Int

    var body: some View {
        HStack(spacing: 9) {
            Text(position.map(String.init) ?? "—")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(position == 1 ? color : .secondary)
                .frame(width: 18)

            ZStack {
                Circle().fill(statusColor.opacity(0.14))
                Image(systemName: rank.host.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(rank.host.displayName)
                        .font(.caption.weight(.semibold))
                    if position == 1 {
                        Text("FASTEST")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    Text(valueLabel)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(rank.snapshot.state == .online ? Color.primary : Color.red)
                    if let deltaLabel {
                        Text(deltaLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        if rank.snapshot.state == .online, let value = rank.valueMilliseconds {
                            Capsule()
                                .fill(color.opacity(0.75))
                                .frame(width: max(5, geometry.size.width * CGFloat(value) / CGFloat(maximumValue)))
                        }
                    }
                }
                .frame(height: 5)

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var valueLabel: String {
        if rank.host.isLocal { return "Local" }
        guard let value = rank.valueMilliseconds else {
            return rank.snapshot.state == .unreachable ? "Unreachable" : "No data"
        }
        return durationLabel(value)
    }

    private var deltaLabel: String? {
        guard rank.snapshot.state == .online,
              let value = rank.valueMilliseconds,
              let bestValue,
              value > bestValue else { return nil }
        return "+\(durationLabel(value - bestValue))"
    }

    private var detail: String {
        if rank.host.isLocal {
            return "Local process timing is not comparable with remote SSH hosts"
        }
        guard rank.snapshot.state == .online else { return rank.snapshot.detail }
        switch metric {
        case .ping:
            let jitter = rank.snapshot.pingJitterMilliseconds.map { "jitter \($0) ms" }
            let loss = rank.snapshot.packetLossPercent.map { String(format: "loss %.1f%%", $0) }
            return [rank.snapshot.routeName, jitter, loss].compactMap { $0 }.joined(separator: " · ")
        case .connectionReady:
            let ping = rank.snapshot.pingMilliseconds.map { "ping \($0) ms" }
            return [ping, rank.snapshot.routeName].compactMap { $0 }.joined(separator: " · ")
        case .checks:
            return "Remote metrics and service work after SSH is ready"
        case .fullProbe:
            let ready = rank.snapshot.connectionReadyMilliseconds.map { "SSH \(durationLabel($0))" }
            let checks = rank.snapshot.probeWorkMilliseconds.map { "checks \(durationLabel($0))" }
            return [ready, checks].compactMap { $0 }.joined(separator: " + ")
        }
    }

    private var statusColor: Color {
        switch rank.snapshot.state {
        case .online: color
        case .checking, .waking: .orange
        case .unreachable: .red
        }
    }

    private var color: Color {
        switch metric {
        case .ping: .green
        case .connectionReady: .blue
        case .checks: .purple
        case .fullProbe: .orange
        }
    }

    private func durationLabel(_ milliseconds: Int) -> String {
        if milliseconds >= 1_000 {
            return String(format: "%.2f s", Double(milliseconds) / 1_000)
        }
        return "\(milliseconds) ms"
    }
}

private struct TrendsView: View {
    @ObservedObject var model: FleetModel
    @State private var selectedHostID = "local"
    @State private var selectedTimestamp: Date?
    @State private var selectedRange: TrendRange = .twentyFourHours

    private var host: FleetHost? {
        model.visibleHosts.first(where: { $0.id == selectedHostID }) ?? model.visibleHosts.first
    }

    private var samples: [MetricSample] {
        guard let host else { return [] }
        return model.samples(for: host.id, hours: selectedRange.hours)
    }

    private var axisMarkCount: Int {
        selectedRange == .sevenDays ? 7 : 4
    }

    private var chartDateFormat: Date.FormatStyle {
        switch selectedRange {
        case .sevenDays: .dateTime.weekday(.abbreviated).hour()
        case .twentyFourHours: .dateTime.hour()
        case .oneHour, .sixHours: .dateTime.hour().minute()
        }
    }

    private var chartEnd: Date {
        model.lastRefresh ?? samples.last?.timestamp ?? Date()
    }

    private var chartDomain: ClosedRange<Date> {
        chartEnd.addingTimeInterval(-selectedRange.hours * 3_600)...chartEnd
    }

    private var selectedSample: MetricSample? {
        guard let selectedTimestamp else { return samples.last }
        return samples.min {
            abs($0.timestamp.timeIntervalSince(selectedTimestamp))
                < abs($1.timestamp.timeIntervalSince(selectedTimestamp))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Range", selection: $selectedRange) {
                    ForEach(TrendRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .frame(width: 145)
                Spacer()
                Picker("Machine", selection: $selectedHostID) {
                    ForEach(model.visibleHosts) { host in
                        Text(host.displayName).tag(host.id)
                    }
                }
                .frame(width: 190)
            }
            .padding(12)

            Divider()

            if let host {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        trendSummary(for: host)
                        latestComparison

                        if samples.count < 2 {
                            ContentUnavailableView(
                                "Collecting history",
                                systemImage: "chart.xyaxis.line",
                                description: Text("Fleetlight needs at least two checks to draw trends.")
                            )
                            .frame(height: 300)
                        } else {
                            if !host.isLocal {
                                pingChart
                            }
                            connectionReadyChart
                            probeDurationChart
                            resourceChart
                        }
                    }
                    .padding(12)
                }
            } else {
                ContentUnavailableView("No visible machines", systemImage: "eye.slash")
            }
        }
        .onAppear { normalizeSelection() }
        .onChange(of: model.visibleHosts.map(\.id)) { _, _ in normalizeSelection() }
        .onChange(of: selectedHostID) { _, _ in selectedTimestamp = nil }
        .onChange(of: selectedRange) { _, _ in selectedTimestamp = nil }
    }

    private func normalizeSelection() {
        if !model.visibleHosts.contains(where: { $0.id == selectedHostID }) {
            selectedHostID = model.visibleHosts.first?.id ?? ""
        }
    }

    private func trendSummary(for host: FleetHost) -> some View {
        let availability = HistoryAnalyzer.availabilityPercent(samples: samples)
        let snapshot = model.snapshots[host.id] ?? HostSnapshot()
        let health = HealthScorer.score(
            snapshot: snapshot,
            availability: availability,
            thresholds: model.performanceThresholds
        )
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            TrendStatCard(
                title: "Health",
                value: "\(health)",
                systemImage: "heart.text.square"
            )
            TrendStatCard(
                title: "Availability",
                value: availability.map { String(format: "%.1f%%", $0) } ?? "—",
                systemImage: "checkmark.circle"
            )
            if !host.isLocal {
                TrendStatCard(
                    title: "Avg ping",
                    value: HistoryAnalyzer.averagePingMilliseconds(samples: samples).map { String(format: "%.0f ms", $0) } ?? "—",
                    systemImage: "arrow.left.and.right"
                )
                TrendStatCard(
                    title: "Avg jitter",
                    value: HistoryAnalyzer.averagePingJitterMilliseconds(samples: samples).map { String(format: "%.0f ms", $0) } ?? "—",
                    systemImage: "waveform.path"
                )
            } else {
                TrendStatCard(
                    title: "Incidents",
                    value: "\(HistoryAnalyzer.incidentCount(samples: samples))",
                    systemImage: "exclamationmark.triangle"
                )
                TrendStatCard(
                    title: "Avg checks",
                    value: HistoryAnalyzer.averageProbeWorkMilliseconds(samples: samples).map { String(format: "%.0f ms", $0) } ?? "—",
                    systemImage: "wrench.and.screwdriver"
                )
            }
            TrendStatCard(
                title: host.isLocal ? "Avg process ready" : "Avg SSH ready",
                value: HistoryAnalyzer.averageConnectionReadyMilliseconds(samples: samples).map { String(format: "%.0f ms", $0) } ?? "—",
                systemImage: "bolt.horizontal"
            )
            TrendStatCard(
                title: "Avg full probe",
                value: HistoryAnalyzer.averageProbeDurationMilliseconds(samples: samples).map { String(format: "%.0f ms", $0) } ?? "—",
                systemImage: "stopwatch"
            )
        }
    }

    @ViewBuilder
    private var latestComparison: some View {
        if let latest = samples.last {
            let comparisons = [
                comparisonText(
                    label: "Ping",
                    current: latest.pingMilliseconds,
                    average: HistoryAnalyzer.averagePingMilliseconds(samples: samples)
                ),
                comparisonText(
                    label: host?.isLocal == true ? "Process" : "SSH",
                    current: latest.connectionReadyMilliseconds,
                    average: HistoryAnalyzer.averageConnectionReadyMilliseconds(samples: samples)
                ),
                comparisonText(
                    label: "Probe",
                    current: latest.effectiveProbeDurationMilliseconds,
                    average: HistoryAnalyzer.averageProbeDurationMilliseconds(samples: samples)
                ),
            ].compactMap { $0 }

            if !comparisons.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Latest vs \(selectedRange.compactLabel) average")
                            .font(.caption.weight(.semibold))
                        Text(comparisons.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(samples.count) checks")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(9)
                .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func comparisonText(label: String, current: Int?, average: Double?) -> String? {
        guard let current, let average, average > 0 else { return nil }
        let change = (Double(current) - average) * 100 / average
        let changeText = abs(change) < 0.5 ? "≈ avg" : String(format: "%+.0f%%", change)
        return "\(label) \(formatDuration(current)) (\(changeText))"
    }

    private var pingChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Network quality")
                    .font(.caption.weight(.semibold))
                Spacer()
                HStack(spacing: 8) {
                    Label("Ping RTT", systemImage: "minus").foregroundStyle(.green)
                    Label("Jitter", systemImage: "minus").foregroundStyle(.cyan)
                    Label("Loss", systemImage: "minus").foregroundStyle(.red)
                }
                .font(.caption2)
            }
            Chart {
                ForEach(samples.filter { $0.pingMilliseconds != nil }) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Milliseconds", sample.pingMilliseconds ?? 0),
                        series: .value("Network metric", "Ping RTT")
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .symbol(.circle)
                    .symbolSize(28)
                }
                ForEach(samples.filter { $0.pingJitterMilliseconds != nil }) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Milliseconds", sample.pingJitterMilliseconds ?? 0),
                        series: .value("Network metric", "Jitter")
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
                ForEach(samples.filter { ($0.packetLossPercent ?? 0) > 0 }) { sample in
                    RuleMark(x: .value("Packet loss", sample.timestamp))
                        .foregroundStyle(.red.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                if let selectedSample {
                    RuleMark(x: .value("Selected time", selectedSample.timestamp))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: chartDomain)
            .chartYAxisLabel("ms")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: axisMarkCount)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: chartDateFormat)
                }
            }
            .chartXSelection(value: $selectedTimestamp)
            .frame(height: 155)

            Label("Left to right is time. Solid = ping, dashed = jitter, red = packet loss.", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
            coverageNotice(
                samples.filter { $0.pingMilliseconds != nil || $0.pingJitterMilliseconds != nil },
                metric: "Network quality"
            )

            if let selectedSample {
                timingReadout(selectedSample)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var connectionReadyChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(host?.isLocal == true ? "Process ready time" : "SSH ready time")
                    .font(.caption.weight(.semibold))
                Spacer()
                HStack(spacing: 8) {
                    Label(host?.isLocal == true ? "Process ready" : "SSH ready", systemImage: "minus").foregroundStyle(.blue)
                    Label("Failed check", systemImage: "minus").foregroundStyle(.red)
                }
                .font(.caption2)
            }
            Chart {
                ForEach(samples.filter { $0.state == .online && $0.connectionReadyMilliseconds != nil }) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Milliseconds", sample.connectionReadyMilliseconds ?? 0),
                        series: .value("Timing", "Ready")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.blue)
                }
                ForEach(samples.filter { $0.state == .unreachable }) { sample in
                    RuleMark(x: .value("Unreachable", sample.timestamp))
                        .foregroundStyle(.red.opacity(0.55))
                }
                if let selectedSample {
                    RuleMark(x: .value("Selected time", selectedSample.timestamp))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: chartDomain)
            .chartYAxisLabel("ms")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: axisMarkCount)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: chartDateFormat)
                }
            }
            .chartXSelection(value: $selectedTimestamp)
            .frame(height: 155)

            coverageNotice(
                samples.filter { $0.connectionReadyMilliseconds != nil },
                metric: host?.isLocal == true ? "Process-ready" : "SSH-ready"
            )

            if host?.isLocal == true, let selectedSample {
                timingReadout(selectedSample)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var probeDurationChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Full probe and checks")
                    .font(.caption.weight(.semibold))
                Spacer()
                HStack(spacing: 8) {
                    Label("Full probe", systemImage: "minus").foregroundStyle(.orange)
                    Label("Checks", systemImage: "minus").foregroundStyle(.purple)
                }
                .font(.caption2)
            }
            Chart {
                ForEach(samples.filter { $0.state == .online && $0.effectiveProbeDurationMilliseconds != nil }) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Milliseconds", sample.effectiveProbeDurationMilliseconds ?? 0),
                        series: .value("Timing", "Full probe")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.orange)
                }
                ForEach(samples.filter { $0.state == .online && $0.probeWorkMilliseconds != nil }) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Milliseconds", sample.probeWorkMilliseconds ?? 0),
                        series: .value("Timing", "Checks")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.purple)
                }
                if let selectedSample {
                    RuleMark(x: .value("Selected time", selectedSample.timestamp))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: chartDomain)
            .chartYAxisLabel("ms")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: axisMarkCount)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: chartDateFormat)
                }
            }
            .chartXSelection(value: $selectedTimestamp)
            .frame(height: 155)

            if samples.contains(where: { $0.timingVersion == nil }) {
                Label("Older records contain full-probe totals only; SSH-ready history starts with Fleetlight 1.4.", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            coverageNotice(
                samples.filter { $0.effectiveProbeDurationMilliseconds != nil },
                metric: "Probe"
            )
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var resourceChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Resource usage")
                    .font(.caption.weight(.semibold))
                Spacer()
                HStack(spacing: 10) {
                    Label("Disk", systemImage: "minus")
                        .foregroundStyle(.orange)
                    Label("Memory", systemImage: "minus")
                        .foregroundStyle(.purple)
                }
                .font(.caption2)
            }
            Chart {
                ForEach(samples.filter { $0.diskPercent != nil }) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Percent", sample.diskPercent ?? 0),
                        series: .value("Resource", "Disk")
                    )
                    .foregroundStyle(.orange)
                }
                ForEach(samples.filter { $0.memoryPercent != nil }) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Percent", sample.memoryPercent ?? 0),
                        series: .value("Resource", "Memory")
                    )
                    .foregroundStyle(.purple)
                }
                if let selectedSample {
                    RuleMark(x: .value("Selected time", selectedSample.timestamp))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: chartDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: axisMarkCount)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: chartDateFormat)
                }
            }
            .chartXSelection(value: $selectedTimestamp)
            .frame(height: 155)
            coverageNotice(
                samples.filter { $0.diskPercent != nil || $0.memoryPercent != nil },
                metric: "Resource"
            )
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func timingReadout(_ sample: MetricSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: sample.state == .online ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(sample.state == .online ? Color.green : Color.red)
                Text(sample.timestamp.formatted(date: .abbreviated, time: .standard))
                    .fontWeight(.semibold)
                Text(sample.state == .online ? "Online" : "Probe failed")
                Spacer()
            }
            .font(.caption2)

            HStack(spacing: 8) {
                if let ping = sample.pingMilliseconds {
                    Text("Ping \(formatDuration(ping))")
                }
                if let jitter = sample.pingJitterMilliseconds {
                    Text("Jitter \(formatDuration(jitter))")
                }
                if let loss = sample.packetLossPercent {
                    Text(String(format: "Loss %.1f%%", loss))
                }
                if let minimum = sample.pingMinimumMilliseconds,
                   let maximum = sample.pingMaximumMilliseconds {
                    Text("Range \(minimum)–\(maximum) ms")
                }
            }
            .font(.caption2)

            HStack(spacing: 8) {
                if let ready = sample.connectionReadyMilliseconds {
                    Text("SSH ready \(formatDuration(ready))")
                }
                if let checks = sample.probeWorkMilliseconds {
                    Text("Checks \(formatDuration(checks))")
                }
                if let probe = sample.effectiveProbeDurationMilliseconds {
                    Text("Full probe \(formatDuration(probe))")
                }
            }
            .font(.caption2)

            Text(sampleDescription(for: sample))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.top, 2)
        .help("Move the pointer across either chart to inspect another sample")
    }

    private func sampleDescription(for sample: MetricSample) -> String {
        let route = "Route: \(sample.routeName ?? "unknown")"
        let detail = sample.detail
            ?? (sample.state == .unreachable ? "No failure reason was stored by this older version" : nil)
        return [route, detail].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func coverageNotice(_ metricSamples: [MetricSample], metric: String) -> some View {
        if let first = metricSamples.first {
            if first.timestamp.timeIntervalSince(chartDomain.lowerBound) > 90 {
                Label(
                    "\(metric) history starts \(first.timestamp.formatted(date: .abbreviated, time: .shortened)); the earlier part of this window has no data.",
                    systemImage: "clock.badge.questionmark"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        } else {
            Label("No \(metric.lowercased()) data in this window.", systemImage: "clock.badge.questionmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds) ms" }
        return String(format: "%.2f s", Double(milliseconds) / 1_000)
    }
}

private enum EventCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case availability
    case services
    case performance
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All categories"
        case .availability: "Availability"
        case .services: "Services"
        case .performance: "Performance"
        case .system: "System"
        }
    }

    func includes(_ event: IncidentEvent) -> Bool {
        self == .all || event.kind.category.rawValue == rawValue
    }
}

private struct EventsView: View {
    @ObservedObject var model: FleetModel
    @State private var selectedHostID = "all"
    @State private var category: EventCategoryFilter = .all
    @State private var activeOnly = false

    private var filteredIncidents: [IncidentEvent] {
        let source = activeOnly ? model.activeIncidents : model.incidents
        return source.filter { event in
            (selectedHostID == "all" || event.hostID == selectedHostID)
                && category.includes(event)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Incident timeline")
                        .font(.headline)
                    Text("Confirmed transitions from the last 30 days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(filteredIncidents.count)")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            HStack(spacing: 8) {
                Picker("Machine", selection: $selectedHostID) {
                    Text("All machines").tag("all")
                    ForEach(model.hosts) { host in
                        Text(host.displayName).tag(host.id)
                    }
                }
                .frame(width: 145)
                Picker("Category", selection: $category) {
                    ForEach(EventCategoryFilter.allCases) { category in
                        Text(category.label).tag(category)
                    }
                }
                .frame(width: 150)
                Button {
                    activeOnly.toggle()
                } label: {
                    Label(
                        "Active",
                        systemImage: activeOnly ? "exclamationmark.circle.fill" : "exclamationmark.circle"
                    )
                }
                .buttonStyle(.borderless)
                .foregroundStyle(activeOnly ? Color.orange : Color.secondary)
                .help(activeOnly ? "Show all incident history" : "Show unresolved active issues only")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            if filteredIncidents.isEmpty {
                ContentUnavailableView(
                    model.incidents.isEmpty
                        ? "No confirmed incidents"
                        : (activeOnly ? "No active issues" : "No matching incidents"),
                    systemImage: "checkmark.shield",
                    description: Text(
                        model.incidents.isEmpty
                            ? "Outages, recoveries, performance warnings, service transitions, route changes, and wake results will appear here."
                            : (activeOnly ? "No unresolved incidents match these filters." : "Choose a different machine or category filter.")
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(filteredIncidents) { event in
                            IncidentRow(
                                event: event,
                                hostName: model.hosts.first(where: { $0.id == event.hostID })?.displayName ?? event.hostID
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct IncidentRow: View {
    let event: IncidentEvent
    let hostName: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.14))
                Image(systemName: event.kind.systemImage)
                    .foregroundStyle(color)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.title)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("\(hostName) · \(event.detail)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private var color: Color {
        switch event.kind {
        case .hostDown, .wakeUnverified: .red
        case .diskWarning, .serviceAttention, .routeChanged, .performanceAttention: .orange
        case .hostRecovered, .serviceRecovered, .wakeVerified, .performanceRecovered: .green
        }
    }
}

private struct FleetSettingsView: View {
    @ObservedObject var model: FleetModel

    var body: some View {
        Form {
            Section("Fleet configuration") {
                LabeledContent("Machines loaded", value: "\(model.hosts.count)")
                HStack {
                    Button("Open fleet.json") { model.openFleetConfiguration() }
                    Button("Reload Configuration") { model.reloadFleetConfiguration() }
                }
                Text("Remote machines use aliases from ~/.ssh/config. Fleetlight stores no SSH passwords or private keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Monitoring") {
                Picker("Refresh interval", selection: Binding(
                    get: { model.refreshInterval },
                    set: { model.setRefreshInterval($0) }
                )) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }

                Toggle("Notify on confirmed outages and recoveries", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { model.setNotificationsEnabled($0) }
                ))
                Toggle("Open Fleetlight at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }

            Section("Visible machines") {
                ForEach(model.hosts) { host in
                    Toggle(host.displayName, isOn: Binding(
                        get: { model.isHostVisible(host) },
                        set: { model.setHostVisible(host, visible: $0) }
                    ))
                }
                Text("Hidden machines continue to be monitored and retained in history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Performance warnings") {
                Stepper(
                    value: thresholdBinding(\.pingWarningMilliseconds),
                    in: 25...1_000,
                    step: 25
                ) {
                    LabeledContent("Ping", value: "\(model.performanceThresholds.pingWarningMilliseconds) ms")
                }
                Stepper(
                    value: thresholdBinding(\.jitterWarningMilliseconds),
                    in: 5...500,
                    step: 5
                ) {
                    LabeledContent("Jitter", value: "\(model.performanceThresholds.jitterWarningMilliseconds) ms")
                }
                Stepper(
                    value: thresholdBinding(\.packetLossWarningPercent),
                    in: 0.5...100,
                    step: 0.5
                ) {
                    LabeledContent(
                        "Packet loss",
                        value: String(format: "%.1f%%", model.performanceThresholds.packetLossWarningPercent)
                    )
                }
                Stepper(
                    value: thresholdBinding(\.connectionReadyWarningMilliseconds),
                    in: 250...10_000,
                    step: 250
                ) {
                    LabeledContent(
                        "SSH ready",
                        value: "\(model.performanceThresholds.connectionReadyWarningMilliseconds) ms"
                    )
                }
                Stepper(
                    value: thresholdBinding(\.fullProbeWarningMilliseconds),
                    in: 500...20_000,
                    step: 500
                ) {
                    LabeledContent(
                        "Full probe",
                        value: "\(model.performanceThresholds.fullProbeWarningMilliseconds) ms"
                    )
                }
                Button("Reset Warning Thresholds") { model.resetPerformanceThresholds() }
                Text("Thresholds affect attention filters, warning colors, health scores, and copied diagnostics. Breaches sustained for two checks and their recoveries are recorded in Events. Notifications remain limited to confirmed outages and service transitions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                LabeledContent("Retention", value: "7 days")
                LabeledContent("Charts", value: "1 hour–7 days")
                LabeledContent("Incident retention", value: "30 days")
                HStack {
                    Button("Export CSV…") { model.exportHistoryCSV() }
                    Button("Reveal Data Folder") { model.revealDataFolder() }
                }
                Text("Metrics stay locally in ~/Library/Application Support/Fleetlight/metrics.jsonl")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 680)
        .padding(12)
    }

    private func thresholdBinding<Value>(
        _ keyPath: WritableKeyPath<PerformanceThresholds, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.performanceThresholds[keyPath: keyPath] },
            set: { value in
                var thresholds = model.performanceThresholds
                thresholds[keyPath: keyPath] = value
                model.setPerformanceThresholds(thresholds)
            }
        )
    }
}

private struct HostRow: View {
    let host: FleetHost
    let snapshot: HostSnapshot
    let availability: Double?
    let healthScore: Int
    let performanceWarnings: [PerformanceWarning]
    let routeTests: [RouteProbeResult]
    let isRefreshing: Bool
    let isPinned: Bool
    let codexUpdate: HostCodexUpdateProgress?
    let latestCodexVersion: String?
    let isCodexUpdateBusy: Bool
    let onTogglePin: () -> Void
    let onWake: () -> Void
    let onSSH: () -> Void
    let onCopy: () -> Void
    let onRefresh: () -> Void
    let onUpdateCodex: () -> Void
    let onTestRoutes: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                statusIcon

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(host.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        Text(host.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Button(action: onTogglePin) {
                            Image(systemName: isPinned ? "star.fill" : "star")
                                .font(.system(size: 10))
                                .foregroundStyle(isPinned ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isPinned ? "Unpin \(host.displayName)" : "Pin \(host.displayName) to the top")
                    }
                    Text(primaryDetail)
                        .font(.caption)
                        .foregroundStyle(snapshot.state == .unreachable ? .red : .secondary)
                        .lineLimit(2)
                    if codexUpdateIsAvailable, let latestCodexVersion, !isCodexUpdateBusy {
                        Label("Codex \(latestCodexVersion) available", systemImage: "arrow.up.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                    if let codexUpdate {
                        Label(codexUpdate.detail, systemImage: codexUpdateSystemImage)
                            .font(.caption2)
                            .foregroundStyle(codexUpdateColor)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                }

                if host.canWake && snapshot.state == .unreachable {
                    Button("Wake", action: onWake)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                if snapshot.state == .online {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? "Hide machine details" : "Show machine details")
                }

                Menu {
                    Button("Refresh This Machine", action: onRefresh)
                        .disabled(isRefreshing)
                    Button("Update Codex", action: onUpdateCodex)
                        .disabled(isCodexUpdateBusy || isRefreshing || snapshot.state != .online)
                    if !host.isLocal {
                        Button("Open SSH", action: onSSH)
                            .disabled(snapshot.state != .online)
                    }
                    if host.routes.count > 1 {
                        Button("Test All Routes", action: onTestRoutes)
                    }
                    Divider()
                    Button("Copy Full Diagnostics", action: onCopy)
                    if host.canWake {
                        Divider()
                        Button("Wake and Verify", action: onWake)
                            .disabled(snapshot.state == .waking)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if isExpanded, snapshot.state == .online {
                expandedDetails
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
        )
    }

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.top, 8)

            HStack(spacing: 6) {
                MetricPill(label: "Health", value: "\(healthScore)", warning: healthScore < 90)
                if let availability {
                    MetricPill(label: "Available", value: String(format: "%.1f%%", availability), warning: availability < 99)
                }
                if let disk = snapshot.diskPercent {
                    MetricPill(label: "Disk", value: "\(disk)%", warning: disk >= 90)
                }
                if let memory = snapshot.memoryPercent {
                    MetricPill(label: "Memory", value: "\(memory)%", warning: memory >= 90)
                }
                if let load = snapshot.loadAverage {
                    MetricPill(label: "Load", value: String(format: "%.2f", load), warning: false)
                }
            }

            if !host.isLocal {
                HStack(spacing: 6) {
                    MetricPill(
                        label: "Ping",
                        value: snapshot.pingMilliseconds.map(durationLabel) ?? "No reply",
                        warning: snapshot.pingMilliseconds == nil || hasPerformanceWarning(.ping)
                    )
                    if let jitter = snapshot.pingJitterMilliseconds {
                        MetricPill(label: "Jitter", value: durationLabel(jitter), warning: hasPerformanceWarning(.jitter))
                    }
                    if let loss = snapshot.packetLossPercent {
                        MetricPill(label: "Loss", value: String(format: "%.1f%%", loss), warning: hasPerformanceWarning(.packetLoss))
                    }
                }
            }

            HStack(spacing: 6) {
                if let ready = snapshot.connectionReadyMilliseconds {
                    MetricPill(label: host.isLocal ? "Process ready" : "SSH ready", value: durationLabel(ready), warning: hasPerformanceWarning(.connectionReady))
                }
                if let duration = snapshot.probeDurationMilliseconds {
                    MetricPill(label: "Full probe", value: durationLabel(duration), warning: hasPerformanceWarning(.fullProbe))
                }
                if let work = snapshot.probeWorkMilliseconds {
                    MetricPill(label: "Checks", value: durationLabel(work), warning: work >= 2_000)
                }
            }

            if !host.isLocal, let diagnosis = NetworkDiagnoser.diagnose(snapshot: snapshot) {
                NetworkDiagnosisView(diagnosis: diagnosis)
            }

            if !performanceWarnings.isEmpty {
                VStack(spacing: 4) {
                    ForEach(performanceWarnings) { warning in
                        PerformanceWarningView(warning: warning)
                    }
                }
            }

            if let route = snapshot.routeName {
                Label("Connected: \(route)", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if host.routes.count > 1 {
                HStack {
                    Text("Recovery routes")
                        .font(.caption2.weight(.semibold))
                    Spacer()
                    Button(routeTests.contains(where: { $0.state == .checking }) ? "Testing…" : "Test All", action: onTestRoutes)
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .disabled(routeTests.contains(where: { $0.state == .checking }))
                }
                if !routeTests.isEmpty {
                    VStack(spacing: 3) {
                        ForEach(routeTests) { result in
                            RouteResultRow(result: result)
                        }
                    }
                }
            }
            if let boot = snapshot.bootDescription {
                Label("Booted \(boot)", systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !snapshot.services.isEmpty {
                VStack(spacing: 4) {
                    ForEach(snapshot.services) { service in
                        ServiceRow(service: service)
                    }
                }
            }
        }
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.14))
            Image(systemName: host.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .frame(width: 34, height: 34)
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        }
    }

    private var statusColor: Color {
        switch snapshot.state {
        case .online:
            return snapshot.needsAttention || !performanceWarnings.isEmpty ? .orange : .green
        case .checking, .waking:
            return .orange
        case .unreachable:
            return .red
        }
    }

    private var codexUpdateSystemImage: String {
        switch codexUpdate?.phase {
        case .notAttempted: "clock"
        case .updating: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .failed: "exclamationmark.triangle.fill"
        case nil: "arrow.up.circle"
        }
    }

    private var codexUpdateIsAvailable: Bool {
        snapshot.state == .online
            && CodexReleaseChecker.isUpdateAvailable(
                installedVersion: snapshot.codexVersion,
                latestVersion: latestCodexVersion
            )
    }

    private var codexUpdateColor: Color {
        switch codexUpdate?.phase {
        case .notAttempted: .secondary
        case .updating: .blue
        case .succeeded: .green
        case .offline: .orange
        case .failed: .red
        case nil: .secondary
        }
    }

    private var primaryDetail: String {
        switch snapshot.state {
        case .checking:
            return "Checking…"
        case .waking:
            return snapshot.detail
        case .unreachable:
            if let diagnosis = NetworkDiagnoser.diagnose(snapshot: snapshot) {
                return "\(diagnosis.title) · \(snapshot.detail)"
            }
            return snapshot.detail
        case .online:
            let os = snapshot.operatingSystem ?? "Online"
            let codex = "Codex \(snapshot.codexVersion ?? "Unknown")"
            let ping = snapshot.pingMilliseconds.map { "Ping \(durationLabel($0))" }
            let ready = snapshot.latencyMilliseconds.map {
                host.isLocal ? "Process \(durationLabel($0))" : "SSH \(durationLabel($0))"
            }
            var facts = [os, codex]
            let serviceAlerts = snapshot.services.filter { $0.state.needsAttention }.count
            if serviceAlerts > 0 {
                facts.append("\(serviceAlerts) service alert\(serviceAlerts == 1 ? "" : "s")")
            } else if let warning = performanceWarnings.first {
                facts.append(warning.kind.displayName)
            } else {
                facts.append(snapshot.detail)
            }
            facts.append(contentsOf: [ping, ready].compactMap { $0 })
            return facts.joined(separator: " · ")
        }
    }

    private func durationLabel(_ milliseconds: Int) -> String {
        if milliseconds >= 1_000 {
            return String(format: "%.2f s", Double(milliseconds) / 1_000)
        }
        return "\(milliseconds) ms"
    }

    private func hasPerformanceWarning(_ kind: PerformanceWarningKind) -> Bool {
        performanceWarnings.contains(where: { $0.kind == kind })
    }
}

private struct RouteResultRow: View {
    let result: RouteProbeResult

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(result.route.displayName)
                .font(.caption2)
            Spacer()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    private var detail: String {
        switch result.state {
        case .checking: "Checking…"
        case .reachable: result.latencyMilliseconds.map { "\($0) ms ready" } ?? "Verified"
        case .unreachable: result.detail
        }
    }

    private var color: Color {
        switch result.state {
        case .checking: .orange
        case .reachable: .green
        case .unreachable: .red
        }
    }
}

private struct SummaryPill: View {
    let label: String
    let value: String
    let color: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold)
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(isSelected ? color.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
        .overlay {
            Capsule()
                .stroke(isSelected ? color.opacity(0.7) : .clear, lineWidth: 1)
        }
    }
}

private struct TrendStatCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct MetricPill: View {
    let label: String
    let value: String
    let warning: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(warning ? .orange : .primary)
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.055), in: Capsule())
    }
}

private struct NetworkDiagnosisView: View {
    let diagnosis: NetworkDiagnosis

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnosis.title)
                    .font(.caption.weight(.semibold))
                Text(diagnosis.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var color: Color {
        switch diagnosis.level {
        case .healthy: .green
        case .notice: .orange
        case .warning: .red
        }
    }

    private var systemImage: String {
        switch diagnosis.level {
        case .healthy: "checkmark.circle"
        case .notice: "waveform.path.ecg"
        case .warning: "exclamationmark.triangle"
        }
    }
}

private struct PerformanceWarningView: View {
    let warning: PerformanceWarning

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(.orange)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.kind.displayName)
                    .font(.caption.weight(.semibold))
                Text(warning.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct ServiceRow: View {
    let service: ServiceSnapshot

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: service.kind.systemImage)
                .frame(width: 14)
                .foregroundStyle(color)
            Text(service.kind.displayName)
                .font(.caption)
            Spacer()
            Text(service.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private var color: Color {
        switch service.state {
        case .healthy: .green
        case .degraded: .orange
        case .stopped: .red
        case .unavailable: .gray
        }
    }
}
