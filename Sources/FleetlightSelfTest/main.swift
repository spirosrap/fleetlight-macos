import Foundation
import FleetlightCore

private final class Harness {
    private(set) var count = 0

    func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        count += 1
    }
}

private let test = Harness()
let route = SSHRoute(alias: "example-via-relay", displayName: "Via Relay")
let verified = CommandResult(
    exitCode: 0,
    stdout: """
    FLEETLIGHT_OK
    OS=Linux
    BOOT=2026-07-11 08:12:03
    CODEX=codex-cli 0.137.0
    CODEX=codex-cli 0.144.2
    CODEX_APP_VERSION=26.707.62119
    CODEX_APP_BUILD=5211
    DISK=42%
    LOAD=0.73
    MEM=38
    SERVICE=tailscale|healthy|Connected
    SERVICE=plex|stopped|Server inactive

    """,
    stderr: "",
    elapsedMilliseconds: 87,
    firstOutputMilliseconds: 23,
    timedOut: false
)
var verifiedSnapshot = ProbeParser.snapshot(from: verified, route: route)
verifiedSnapshot.pingMilliseconds = 42
verifiedSnapshot.pingMinimumMilliseconds = 35
verifiedSnapshot.pingMaximumMilliseconds = 51
verifiedSnapshot.pingJitterMilliseconds = 6
verifiedSnapshot.packetLossPercent = 0
test.require(verifiedSnapshot.state == .online, "verified probe should be online")
test.require(verifiedSnapshot.operatingSystem == "Linux", "OS should be parsed")
test.require(verifiedSnapshot.codexVersion == "0.144.2", "newest Codex CLI version should win when duplicate installs exist")
test.require(verifiedSnapshot.codexDesktopAppVersion == "26.707.62119", "Codex desktop app version should be parsed separately from the CLI")
test.require(verifiedSnapshot.codexDesktopAppBuild == "5211", "Codex desktop app build should be retained")
test.require(verifiedSnapshot.diskPercent == 42, "disk percentage should be parsed")
test.require(verifiedSnapshot.memoryPercent == 38, "memory percentage should be parsed")
test.require(verifiedSnapshot.loadAverage == 0.73, "load average should be parsed")
test.require(verifiedSnapshot.latencyMilliseconds == 23, "connection-ready time should use first output")
test.require(verifiedSnapshot.probeDurationMilliseconds == 87, "full probe duration should be retained")
test.require(verifiedSnapshot.probeWorkMilliseconds == 64, "probe work should exclude connection readiness")
test.require(verifiedSnapshot.pingMilliseconds == 42, "ping should remain separate from SSH readiness")
test.require(verifiedSnapshot.pingJitterMilliseconds == 6, "ping jitter should be retained")
test.require(verifiedSnapshot.routeName == "Via Relay", "route name should be retained")
test.require(verifiedSnapshot.routeAlias == "example-via-relay", "route alias should be retained")
test.require(verifiedSnapshot.services.count == 2, "service results should be parsed")
test.require(verifiedSnapshot.services[0].kind == .tailscale, "service kind should be parsed")
test.require(verifiedSnapshot.services[0].state == .healthy, "healthy service state should be parsed")
test.require(verifiedSnapshot.services[1].state == .stopped, "stopped service state should be parsed")
test.require(verifiedSnapshot.needsAttention, "stopped service should flag its host")

let unverified = CommandResult(
    exitCode: 0,
    stdout: "Linux\n",
    stderr: "",
    elapsedMilliseconds: 50,
    timedOut: false
)
let unverifiedSnapshot = ProbeParser.snapshot(from: unverified)
test.require(unverifiedSnapshot.state == .unreachable, "missing verification marker must not be online")
test.require(unverifiedSnapshot.detail.contains("verification marker"), "missing marker should be explained")

let timeout = CommandResult(
    exitCode: 15,
    stdout: "",
    stderr: "",
    elapsedMilliseconds: 9_011,
    timedOut: true
)
let timeoutSnapshot = ProbeParser.snapshot(from: timeout)
test.require(timeoutSnapshot.state == .unreachable, "timeout should be unreachable")
test.require(timeoutSnapshot.detail == "Timed out after 9 seconds", "timeout should be truthful")
test.require(timeoutSnapshot.latencyMilliseconds == nil, "failed connections should not invent ready latency")
test.require(timeoutSnapshot.probeDurationMilliseconds == 9_011, "failed probes should retain total duration")

let host = FleetHost(
    id: "example",
    displayName: "Example",
    systemImage: "desktopcomputer",
    services: [.tailscale, .plex]
)
let report = FleetReportBuilder.build(hosts: [host], snapshots: [host.id: verifiedSnapshot])
test.require(report.contains("Example [example]: Online"), "report should identify the host")
test.require(report.contains("Codex 0.144.2"), "report should include the current Codex CLI version")
test.require(report.contains("Codex app 26.707.62119 (build 5211)"), "report should include the Codex desktop app version")
test.require(report.contains("disk 42%"), "report should include disk usage")
test.require(report.contains("memory 38%"), "report should include memory usage")
test.require(report.contains("load 0.73"), "report should include load average")
test.require(report.contains("ping 42 ms"), "report should include network ping")
test.require(report.contains("ping range 35-51 ms"), "report should include ping range")
test.require(report.contains("jitter 6 ms"), "report should include ping jitter")
test.require(report.contains("loss 0.0%"), "report should include packet loss")
test.require(report.contains("Network diagnosis:"), "report should include a plain-language network diagnosis")
test.require(report.contains("route Via Relay"), "report should include the working route")
test.require(report.contains("Plex: stopped"), "report should include service health")

let appHost = FleetHost(
    id: "example-mac",
    displayName: "Example Mac",
    systemImage: "desktopcomputer",
    supportsCodexDesktopApp: true
)
let offlineAppHost = FleetHost(
    id: "offline-mac",
    displayName: "Offline Mac",
    systemImage: "desktopcomputer",
    supportsCodexDesktopApp: true
)
let missingAppHost = FleetHost(
    id: "missing-mac",
    displayName: "Missing Mac",
    systemImage: "desktopcomputer",
    supportsCodexDesktopApp: true
)
let appCheckedAt = Date(timeIntervalSince1970: 1_782_900_000)
let appSnapshot = HostSnapshot(
    state: .online,
    checkedAt: appCheckedAt,
    codexDesktopAppVersion: "26.707.62119",
    codexDesktopAppBuild: "5211"
)
let appSnapshots = [
    appHost.id: appSnapshot,
    offlineAppHost.id: HostSnapshot(state: .unreachable),
    missingAppHost.id: HostSnapshot(state: .online)
]
let appSummary = CodexDesktopAppReportBuilder.summarize(
    hosts: [appHost, offlineAppHost, missingAppHost, host],
    snapshots: appSnapshots
)
test.require(appSummary.installedCount == 1, "Mac app summary should count installed versions")
test.require(appSummary.offlineCount == 1, "Mac app summary should count offline hosts")
test.require(appSummary.missingCount == 1, "Mac app summary should count missing installs")
test.require(appSummary.checkingCount == 0, "Mac app summary should ignore unsupported hosts")
let appReport = CodexDesktopAppReportBuilder.build(
    hosts: [appHost, offlineAppHost, missingAppHost, host],
    snapshots: appSnapshots,
    generatedAt: appCheckedAt
)
test.require(appReport.contains("Configured 3 · Installed 1 · Offline 1 · Missing 1"), "Mac app report should summarize fleet state")
test.require(appReport.contains("Example Mac: Installed 26.707.62119 (build 5211)"), "Mac app report should include the signed version and build")
test.require(appReport.contains("checked"), "Mac app report should include the last check time")

let command = RemoteCommandBuilder.build(services: [.tailscale, .plex, .samba])
test.require(command.hasPrefix("printf 'FLEETLIGHT_OK"), "remote command should emit the verification marker before metrics")
test.require(command.contains("CODEX=%s"), "remote command should emit Codex CLI status")
test.require(command.contains("CODEX_APP_VERSION=%s"), "remote command should emit the signed Codex desktop app version on macOS")
test.require(command.contains("find \"$HOME/.nvm/versions/node\""), "remote command should inspect every NVM Codex install without shell glob failures")
test.require(command.contains("!seen[$0]++"), "remote command should avoid probing duplicate Codex paths")
test.require(command.contains("SERVICE=tailscale"), "remote command should include Tailscale")
test.require(command.contains("SERVICE=plex"), "remote command should include Plex")
test.require(command.contains("SERVICE=samba"), "remote command should include Samba")
test.require(!command.contains("SERVICE=docker"), "remote command should exclude unconfigured services")

let noCodexResult = CommandResult(
    exitCode: 0,
    stdout: "FLEETLIGHT_OK\nCODEX=not-installed\n",
    stderr: "",
    elapsedMilliseconds: 20,
    timedOut: false
)
test.require(ProbeParser.snapshot(from: noCodexResult).codexVersion == "Not installed", "missing Codex CLI should be explicit instead of unknown")

let latestCodexJSON = #"{"version":"0.144.3"}"#
test.require(CodexReleaseChecker.latestVersion(fromRegistryJSON: latestCodexJSON) == "0.144.3", "npm latest metadata should expose the published Codex version")
test.require(CodexReleaseChecker.latestVersion(fromRegistryJSON: #"{"version":"v0.145.0"}"#) == "0.145.0", "published Codex versions should normalize an optional v prefix")
test.require(CodexReleaseChecker.latestVersion(fromRegistryJSON: #"{"version":"invalid"}"#) == nil, "invalid registry versions should be rejected")
test.require(CodexReleaseChecker.isUpdateAvailable(installedVersion: "0.144.2", latestVersion: "0.144.3"), "older Codex installations should show an available update")
test.require(!CodexReleaseChecker.isUpdateAvailable(installedVersion: "0.144.3", latestVersion: "0.144.3"), "the published Codex version should be reported as current")
test.require(!CodexReleaseChecker.isUpdateAvailable(installedVersion: "0.145.0-alpha.1", latestVersion: "0.144.3"), "newer prerelease installations should not be offered a downgrade")
test.require(CodexReleaseChecker.isUpdateAvailable(installedVersion: "0.145.0-alpha.1", latestVersion: "0.145.0"), "a stable release should supersede the matching prerelease")
test.require(!CodexReleaseChecker.isUpdateAvailable(installedVersion: "Not installed", latestVersion: "0.144.3"), "non-version installation states should not produce false update badges")
test.require(CodexReleaseChecker.isComparableVersion("codex-cli 0.144.3"), "reported Codex CLI versions should be recognized as comparable")
test.require(!CodexReleaseChecker.isComparableVersion("Unavailable"), "non-version Codex states should not be treated as comparable")

let codexPlannerHosts = [
    FleetHost(id: "outdated", displayName: "Outdated", systemImage: "desktopcomputer"),
    FleetHost(id: "current", displayName: "Current", systemImage: "desktopcomputer"),
    FleetHost(id: "offline", displayName: "Offline", systemImage: "desktopcomputer"),
    FleetHost(id: "missing", displayName: "Missing", systemImage: "desktopcomputer"),
]
let codexPlannerSnapshots = [
    "outdated": HostSnapshot(state: .online, codexVersion: "0.144.2"),
    "current": HostSnapshot(state: .online, codexVersion: "0.144.3"),
    "offline": HostSnapshot(state: .unreachable, codexVersion: "0.140.0"),
    "missing": HostSnapshot(state: .online, codexVersion: "Not installed"),
]
let codexAvailableHosts = CodexUpdatePlanner.availableHosts(
    hosts: codexPlannerHosts,
    snapshots: codexPlannerSnapshots,
    latestVersion: "0.144.3"
)
test.require(codexAvailableHosts.map(\.id) == ["outdated"], "smart Codex updates should target only outdated online machines")
test.require(
    CodexUpdatePlanner.availableHosts(
        hosts: codexPlannerHosts,
        snapshots: codexPlannerSnapshots,
        latestVersion: nil
    ).isEmpty,
    "smart Codex updates should wait until the latest stable version is known"
)

test.require(
    CodexFleetVersionAnalyzer.state(
        snapshot: codexPlannerSnapshots["outdated"]!,
        latestVersion: "0.144.3"
    ) == .updateAvailable,
    "the Codex dashboard should classify older online installations as updateable"
)
test.require(
    CodexFleetVersionAnalyzer.state(
        snapshot: codexPlannerSnapshots["current"]!,
        latestVersion: "0.144.3"
    ) == .current,
    "the Codex dashboard should classify matching versions as current"
)
test.require(
    CodexFleetVersionAnalyzer.state(
        snapshot: HostSnapshot(state: .online, codexVersion: "0.145.0"),
        latestVersion: "0.144.3"
    ) == .current,
    "the Codex dashboard should not offer a downgrade to newer installations"
)
test.require(
    CodexFleetVersionAnalyzer.state(
        snapshot: codexPlannerSnapshots["offline"]!,
        latestVersion: "0.144.3"
    ) == .offline,
    "the Codex dashboard should keep connection failures separate from version state"
)
test.require(
    CodexFleetVersionAnalyzer.state(
        snapshot: codexPlannerSnapshots["missing"]!,
        latestVersion: "0.144.3"
    ) == .unavailable,
    "the Codex dashboard should identify missing installations as unavailable"
)
test.require(
    CodexFleetVersionAnalyzer.state(
        snapshot: codexPlannerSnapshots["current"]!,
        latestVersion: nil
    ) == .unavailable,
    "the Codex dashboard should avoid claiming current status before a release check"
)
let codexFleetVersionSummary = CodexFleetVersionAnalyzer.summarize(
    hosts: codexPlannerHosts,
    snapshots: codexPlannerSnapshots,
    latestVersion: "0.144.3"
)
test.require(
    codexFleetVersionSummary == CodexFleetVersionSummary(
        currentCount: 1,
        updateAvailableCount: 1,
        offlineCount: 1,
        unavailableCount: 1
    ),
    "the Codex dashboard summary should count every configured machine exactly once"
)

let retryableCodexHostIDs = CodexUpdateRecoveryPlanner.retryHostIDs(
    orderedHostIDs: ["offline", "current", "failed", "outdated"],
    problemHostIDs: ["offline", "failed"],
    onlineHostIDs: ["current", "failed", "outdated"]
)
test.require(retryableCodexHostIDs == ["failed"], "Codex recovery should retry only problem machines that are currently online")
test.require(
    CodexUpdateRecoveryPlanner.retryHostIDs(
        orderedHostIDs: ["failed", "offline"],
        problemHostIDs: ["failed", "offline"],
        onlineHostIDs: []
    ).isEmpty,
    "Codex recovery should keep unreachable problems pending instead of retrying them immediately"
)

let codexUpdateCommand = CodexUpdateCommandBuilder.build()
test.require(codexUpdateCommand.hasPrefix("printf 'FLEETLIGHT_CODEX_UPDATE"), "Codex updater should emit a verification marker before changing anything")
test.require(codexUpdateCommand.contains("$shell_bin\" -ic 'codex update'"), "Codex updater should honor interactive-shell functions and wrappers")
test.require(codexUpdateCommand.contains("FLEETLIGHT_PATH="), "Codex updater should capture the interactive PATH for executable fallback")
test.require(codexUpdateCommand.contains("[ -x \"$directory/codex\" ]"), "Codex updater should reject non-executable aliases and shell function names")
test.require(codexUpdateCommand.contains("\"$codex_bin\" update"), "Codex updater should retain a direct executable fallback")

let successfulCodexUpdate = CommandResult(
    exitCode: 0,
    stdout: "FLEETLIGHT_CODEX_UPDATE\nBEFORE_VERSION:0.137.0\nACTIVE_VERSION:0.144.2\nUPDATE:ok\nVERIFY:ok\n",
    stderr: "",
    elapsedMilliseconds: 1_250,
    timedOut: false
)
let successfulCodexOutcome = CodexUpdateParser.outcome(from: successfulCodexUpdate)
test.require(successfulCodexOutcome.succeeded, "verified Codex updates should succeed")
test.require(successfulCodexOutcome.activeVersion == "0.144.2", "verified Codex updates should report the active version")

let missingCodexUpdate = CommandResult(
    exitCode: 2,
    stdout: "FLEETLIGHT_CODEX_UPDATE\nUPDATE:missing\nVERIFY:failed\n",
    stderr: "",
    elapsedMilliseconds: 50,
    timedOut: false
)
test.require(CodexUpdateParser.outcome(from: missingCodexUpdate).detail == "Codex is not installed", "missing Codex should have a clear update failure")

let timedOutCodexUpdate = CommandResult(
    exitCode: 15,
    stdout: "FLEETLIGHT_CODEX_UPDATE\n",
    stderr: "",
    elapsedMilliseconds: 300_000,
    timedOut: true
)
test.require(CodexUpdateParser.outcome(from: timedOutCodexUpdate).detail == "Update timed out", "Codex update timeouts should be explicit")

let offlineCodexUpdate = CommandResult(
    exitCode: 255,
    stdout: "",
    stderr: "ssh: connect to host example port 22: Connection timed out",
    elapsedMilliseconds: 12_000,
    timedOut: false
)
let offlineCodexOutcome = CodexUpdateParser.outcome(from: offlineCodexUpdate)
test.require(offlineCodexOutcome.status == .offline, "SSH connection failures should be separate from updater failures")
test.require(offlineCodexOutcome.detail == "Offline — SSH timed out", "offline Codex updates should explain the connection problem")

let codexDesktopAppCommand = CodexDesktopAppUpdateCommandBuilder.build()
test.require(codexDesktopAppCommand.hasPrefix("printf 'FLEETLIGHT_CODEX_APP_UPDATE"), "Codex app updater should emit a verification marker")
test.require(codexDesktopAppCommand.contains("com.openai.codex"), "Codex app updater should verify the OpenAI bundle identifier")
test.require(codexDesktopAppCommand.contains("Check for Updates…"), "Codex app updater should delegate to the app’s own update menu")
test.require(codexDesktopAppCommand.contains("Install and Relaunch"), "Codex app updater should accept Sparkle’s relaunch action")
test.require(codexDesktopAppCommand.contains("AFTER_BUILD:"), "Codex app updater should verify the installed build after relaunch")

let currentCodexDesktopApp = CommandResult(
    exitCode: 0,
    stdout: "FLEETLIGHT_CODEX_APP_UPDATE\nBEFORE_VERSION:26.707.62119\nBEFORE_BUILD:5211\nAFTER_VERSION:26.707.62119\nAFTER_BUILD:5211\nUPDATE:current\nVERIFY:current\n",
    stderr: "",
    elapsedMilliseconds: 1_500,
    timedOut: false
)
let currentCodexDesktopOutcome = CodexDesktopAppUpdateParser.outcome(from: currentCodexDesktopApp)
test.require(currentCodexDesktopOutcome.status == .current, "an up-to-date Codex app should be a successful current result")
test.require(currentCodexDesktopOutcome.activeBuild == "5211", "current Codex app results should retain the verified build")

let updatedCodexDesktopApp = CommandResult(
    exitCode: 0,
    stdout: "FLEETLIGHT_CODEX_APP_UPDATE\nBEFORE_VERSION:26.707.62119\nBEFORE_BUILD:5211\nAFTER_VERSION:26.708.10000\nAFTER_BUILD:5220\nUPDATE:ok\nVERIFY:updated\n",
    stderr: "",
    elapsedMilliseconds: 48_000,
    timedOut: false
)
let updatedCodexDesktopOutcome = CodexDesktopAppUpdateParser.outcome(from: updatedCodexDesktopApp)
test.require(updatedCodexDesktopOutcome.status == .updated, "a changed signed app build should be reported as updated")
test.require(updatedCodexDesktopOutcome.detail.contains("26.708.10000"), "updated Codex app results should name the installed version")

let permissionDeniedCodexDesktopApp = CommandResult(
    exitCode: 3,
    stdout: "FLEETLIGHT_CODEX_APP_UPDATE\nBEFORE_VERSION:26.707.62119\nBEFORE_BUILD:5211\nUPDATE:permission\nVERIFY:failed\n",
    stderr: "",
    elapsedMilliseconds: 400,
    timedOut: false
)
test.require(
    CodexDesktopAppUpdateParser.outcome(from: permissionDeniedCodexDesktopApp).detail.contains("Privacy & Security"),
    "macOS automation denials should explain where to grant permission"
)

let defaultHost = FleetHost.defaults.first!
test.require(FleetHost.defaults.count == 1, "the public default fleet should contain only this Mac")
test.require(defaultHost.id == "local" && defaultHost.isLocal, "the public default should not contain a private SSH target")
test.require(defaultHost.services.isEmpty, "the public default should not reveal configured services")
test.require(defaultHost.supportsCodexDesktopApp, "the safe local default should expose Codex desktop app updates")

let metricFromSnapshot = MetricSample(hostID: "example", snapshot: verifiedSnapshot)
test.require(metricFromSnapshot.routeName == "Via Relay", "metric samples should retain the route")
test.require(metricFromSnapshot.pingMilliseconds == 42, "metric samples should retain ping")
test.require(metricFromSnapshot.pingJitterMilliseconds == 6, "metric samples should retain jitter")
test.require(metricFromSnapshot.packetLossPercent == 0, "metric samples should retain packet loss")
test.require(metricFromSnapshot.serviceAttentionCount == 1, "metric samples should count service alerts")
test.require(metricFromSnapshot.detail == verifiedSnapshot.detail, "metric samples should retain probe details")

let history = [
    MetricSample(hostID: "example", state: .online, pingMilliseconds: 10, pingJitterMilliseconds: 2, packetLossPercent: 0, latencyMilliseconds: 100, probeDurationMilliseconds: 150),
    MetricSample(hostID: "example", state: .unreachable),
    MetricSample(hostID: "example", state: .online, pingMilliseconds: 20, pingJitterMilliseconds: 4, packetLossPercent: 0, latencyMilliseconds: 200, probeDurationMilliseconds: 250, serviceAttentionCount: 1),
    MetricSample(hostID: "example", state: .online, pingMilliseconds: 30, pingJitterMilliseconds: 6, packetLossPercent: 3, latencyMilliseconds: 300, probeDurationMilliseconds: 350),
    MetricSample(hostID: "example", state: .unreachable),
]
test.require(HistoryAnalyzer.availabilityPercent(samples: history) == 60, "availability should include unreachable samples")
test.require(HistoryAnalyzer.averageConnectionReadyMilliseconds(samples: history) == 200, "average ready time should use online samples")
test.require(HistoryAnalyzer.averagePingMilliseconds(samples: history) == 20, "average ping should use online samples")
test.require(HistoryAnalyzer.averagePingJitterMilliseconds(samples: history) == 4, "average jitter should use measured samples")
test.require(HistoryAnalyzer.averagePacketLossPercent(samples: history) == 1, "average packet loss should use measured samples")
test.require(HistoryAnalyzer.averageProbeDurationMilliseconds(samples: history) == 250, "average probe duration should remain separate")
test.require(HistoryAnalyzer.averageProbeWorkMilliseconds(samples: history) == 50, "average check work should remain separate")
test.require(HistoryAnalyzer.incidentCount(samples: history) == 2, "incident transitions should be counted")
test.require(HistoryAnalyzer.availabilityPercent(samples: []) == nil, "empty history should not invent availability")

let windowNow = ISO8601DateFormatter().date(from: "2026-07-12T12:00:00Z")!
let windowHistory = [
    MetricSample(timestamp: windowNow.addingTimeInterval(-7_200), hostID: "example", state: .online),
    MetricSample(timestamp: windowNow.addingTimeInterval(-1_800), hostID: "example", state: .online),
    MetricSample(timestamp: windowNow.addingTimeInterval(-3_600), hostID: "example", state: .online),
]
let oneHourHistory = HistoryAnalyzer.recentSamples(windowHistory, hours: 1, now: windowNow)
test.require(oneHourHistory.count == 2, "one-hour trends should include the cutoff sample")
test.require(oneHourHistory.first?.timestamp == windowNow.addingTimeInterval(-3_600), "trend samples should remain chronological")
test.require(HistoryAnalyzer.recentSamples(windowHistory, hours: 6, now: windowNow).count == 3, "wider trend ranges should include older samples")

let fastHost = FleetHost(id: "fast", displayName: "Fast", systemImage: "desktopcomputer")
let slowHost = FleetHost(id: "slow", displayName: "Slow", systemImage: "desktopcomputer")
let offlineHost = FleetHost(id: "offline", displayName: "Offline", systemImage: "desktopcomputer")
let comparisonSnapshots = [
    "fast": HostSnapshot(state: .online, pingMilliseconds: 20, latencyMilliseconds: 200, probeDurationMilliseconds: 500),
    "slow": HostSnapshot(state: .online, pingMilliseconds: 80, latencyMilliseconds: 600, probeDurationMilliseconds: 1_500),
    "offline": HostSnapshot(state: .unreachable, pingMilliseconds: 10, probeDurationMilliseconds: 5_000),
]
let pingRanks = FleetTimingRanker.rank(
    hosts: [slowHost, offlineHost, fastHost],
    snapshots: comparisonSnapshots,
    metric: .ping
)
test.require(pingRanks.map(\.host.id) == ["fast", "slow", "offline"], "online machines should rank before unreachable machines")
test.require(pingRanks.map(\.valueMilliseconds) == [20, 80, 10], "timing rank should retain measured values")
let readyRanks = FleetTimingRanker.rank(
    hosts: [slowHost, fastHost],
    snapshots: comparisonSnapshots,
    metric: .connectionReady
)
test.require(readyRanks.map(\.host.id) == ["fast", "slow"], "SSH-ready ranking should use connection timing")
let localComparisonHost = FleetHost(id: "local", displayName: "Local", systemImage: "laptopcomputer", isLocal: true)
let localComparison = FleetTimingRanker.rank(
    hosts: [localComparisonHost, fastHost],
    snapshots: [
        "local": HostSnapshot(state: .online, latencyMilliseconds: 1, probeDurationMilliseconds: 10),
        "fast": comparisonSnapshots["fast"]!,
    ],
    metric: .connectionReady
)
test.require(localComparison.first?.host.id == "fast", "local process startup must not outrank remote SSH timing")
test.require(localComparison.last?.valueMilliseconds == nil, "local timing should be marked not comparable")
let checkRanks = FleetTimingRanker.rank(
    hosts: [slowHost, fastHost],
    snapshots: comparisonSnapshots,
    metric: .checks
)
test.require(checkRanks.map(\.valueMilliseconds) == [300, 900], "check ranking should subtract SSH readiness from full probe")
let comparisonReport = FleetComparisonReportBuilder.build(metric: .ping, ranks: pingRanks, generatedAt: windowNow)
test.require(comparisonReport.contains("Fleetlight comparison — Ping"), "comparison report should identify the metric")
test.require(comparisonReport.contains("Fast: 20 ms · fastest"), "comparison report should mark the fastest machine")
test.require(comparisonReport.contains("Slow: 80 ms · +60 ms"), "comparison report should show the gap from fastest")

let sortingSnapshots = [
    "fast": HostSnapshot(state: .online, pingMilliseconds: 20),
    "slow": HostSnapshot(state: .online, pingMilliseconds: 250),
    "offline": HostSnapshot(state: .unreachable),
]
let issueSortedHosts = FleetHostSorter.sort(
    hosts: [slowHost, fastHost, offlineHost],
    snapshots: sortingSnapshots,
    thresholds: .default,
    pinnedHostIDs: [],
    mode: .priority
)
test.require(issueSortedHosts.map(\.id) == ["offline", "slow", "fast"], "issues-first sorting should rank unreachable then warning then healthy machines")
let pinnedSortedHosts = FleetHostSorter.sort(
    hosts: [slowHost, fastHost, offlineHost],
    snapshots: sortingSnapshots,
    thresholds: .default,
    pinnedHostIDs: ["fast"],
    mode: .priority
)
test.require(pinnedSortedHosts.map(\.id) == ["fast", "offline", "slow"], "pinned machines should remain above the selected sort order")
test.require(
    FleetHostSorter.sort(hosts: [slowHost, offlineHost, fastHost], snapshots: sortingSnapshots, thresholds: .default, pinnedHostIDs: [], mode: .ping).map(\.id)
        == ["fast", "slow", "offline"],
    "ping sorting should place measured online machines first from fastest to slowest"
)
test.require(
    FleetHostSorter.sort(hosts: [slowHost, offlineHost, fastHost], snapshots: sortingSnapshots, thresholds: .default, pinnedHostIDs: [], mode: .name).map(\.id)
        == ["fast", "offline", "slow"],
    "name sorting should be alphabetical"
)
test.require(
    FleetHostSorter.sort(hosts: [fastHost, slowHost, offlineHost], snapshots: sortingSnapshots, thresholds: .default, pinnedHostIDs: [], mode: .health).map(\.id)
        == ["offline", "slow", "fast"],
    "health sorting should surface the lowest live health first"
)

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let roundTrippedMetric = try decoder.decode(MetricSample.self, from: encoder.encode(metricFromSnapshot))
test.require(roundTrippedMetric.id == metricFromSnapshot.id, "metric sample identity should round-trip through JSONL encoding")
test.require(roundTrippedMetric.hostID == metricFromSnapshot.hostID, "metric sample host should round-trip through JSONL encoding")
test.require(roundTrippedMetric.routeName == metricFromSnapshot.routeName, "metric sample route should round-trip through JSONL encoding")
test.require(roundTrippedMetric.pingMilliseconds == metricFromSnapshot.pingMilliseconds, "metric ping should round-trip through JSONL encoding")
test.require(roundTrippedMetric.pingJitterMilliseconds == metricFromSnapshot.pingJitterMilliseconds, "metric jitter should round-trip through JSONL encoding")
test.require(roundTrippedMetric.packetLossPercent == metricFromSnapshot.packetLossPercent, "metric packet loss should round-trip through JSONL encoding")
test.require(roundTrippedMetric.detail == metricFromSnapshot.detail, "metric sample detail should round-trip through JSONL encoding")

let thisMac = FleetHost.defaults.first(where: { $0.id == "local" })!
test.require(thisMac.isLocal, "This Mac should use a local probe")
test.require(thisMac.routes.first?.alias == "local", "This Mac should not SSH into itself")

let configuredServer = FleetHost(
    id: "example-server",
    displayName: "Example Server",
    systemImage: "server.rack",
    wakeMACAddress: "00:11:22:33:44:55",
    services: [.tailscale, .docker],
    routes: [SSHRoute(alias: "example-server", displayName: "Direct")]
)
let publicConfiguration = FleetConfiguration(hosts: [thisMac, configuredServer])
test.require(publicConfiguration.validationErrors.isEmpty, "a generic public fleet configuration should validate")
test.require(configuredServer.canWake, "a configured MAC address should enable Wake-on-LAN")
test.require(!configuredServer.supportsCodexDesktopApp, "remote hosts should opt in to Codex desktop app updates")
let configurationRoundTrip = try decoder.decode(FleetConfiguration.self, from: encoder.encode(publicConfiguration))
test.require(configurationRoundTrip == publicConfiguration, "fleet configuration should round-trip through JSON")
let duplicateConfiguration = FleetConfiguration(hosts: [thisMac, thisMac])
test.require(duplicateConfiguration.validationErrors.contains("Machine IDs must be unique"), "duplicate machine IDs should be rejected")

test.require(HealthScorer.score(snapshot: verifiedSnapshot, availability: 100) == 80, "service alerts and fallback routes should reduce health score")
let unreachableHealth = HealthScorer.score(snapshot: timeoutSnapshot, availability: 99)
test.require(unreachableHealth == 0, "unreachable hosts should have zero health")

let incident = IncidentEvent(
    hostID: "example",
    kind: .routeChanged,
    title: "Route changed",
    detail: "Direct to relay"
)
let incidentRoundTrip = try decoder.decode(IncidentEvent.self, from: encoder.encode(incident))
test.require(incidentRoundTrip.id == incident.id, "incident identity should round-trip")
test.require(incidentRoundTrip.kind == .routeChanged, "incident kind should round-trip")
test.require(incident.kind.systemImage == "arrow.triangle.branch", "incident kind should expose its UI symbol")

let routeResult = RouteProbeResult(
    route: route,
    state: .reachable,
    latencyMilliseconds: 42,
    detail: "Verified"
)
test.require(routeResult.id == route.alias, "route results should use stable route identity")
test.require(routeResult.state == .reachable, "route result state should be retained")

let csvSample = MetricSample(
    hostID: "example",
    state: .online,
    pingMilliseconds: 21,
    pingMinimumMilliseconds: 17,
    pingMaximumMilliseconds: 27,
    pingJitterMilliseconds: 3,
    packetLossPercent: 0,
    latencyMilliseconds: 42,
    probeDurationMilliseconds: 84,
    routeName: "Via relay, north",
    detail: "Root disk 42% used"
)
let csv = HistoryCSVBuilder.build(samples: [csvSample])
test.require(csv.hasPrefix("timestamp,host,state"), "CSV export should include a header")
test.require(csv.contains("\"Via relay, north\""), "CSV export should quote commas")
test.require(csv.contains(",21,17,27,3,0.0,42,84,42,"), "CSV export should separate network quality and probe timings")
test.require(csv.contains("Root disk 42% used"), "CSV export should include probe details")

let legacyJSON = """
{"id":"00000000-0000-0000-0000-000000000001","timestamp":"2026-07-12T00:00:00Z","hostID":"legacy","state":"online","latencyMilliseconds":2200,"serviceAttentionCount":0}
""".data(using: .utf8)!
let legacySample = try decoder.decode(MetricSample.self, from: legacyJSON)
test.require(legacySample.connectionReadyMilliseconds == nil, "legacy probe time must not become connection latency")
test.require(legacySample.effectiveProbeDurationMilliseconds == 2_200, "legacy timing should remain probe duration")
test.require(legacySample.pingMilliseconds == nil, "legacy history should decode without invented ping")
test.require(legacySample.pingJitterMilliseconds == nil, "legacy history should decode without invented jitter")

let macPingOutput = """
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 74.667/89.517/98.463/10.574 ms
"""
test.require(PingParser.averageMilliseconds(from: macPingOutput) == 90, "macOS ping average should be parsed and rounded")
let macPing = PingParser.measurement(from: macPingOutput)
test.require(macPing?.minimumMilliseconds == 75, "ping minimum should be parsed")
test.require(macPing?.maximumMilliseconds == 98, "ping maximum should be parsed")
test.require(macPing?.jitterMilliseconds == 11, "ping jitter should be parsed")
test.require(macPing?.packetLossPercent == 0, "packet loss should be parsed")
let linuxPingOutput = "rtt min/avg/max/mdev = 10.100/12.600/15.200/1.000 ms"
test.require(PingParser.averageMilliseconds(from: linuxPingOutput) == 13, "Linux ping average should be parsed")
test.require(PingParser.averageMilliseconds(from: "100% packet loss") == nil, "packet loss should not invent ping")
test.require(PingParser.measurement(from: "3 packets transmitted, 0 packets received, 100.0% packet loss")?.packetLossPercent == 100, "total packet loss should still be recorded")

let nanPingOutput = """
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = nan/nan/nan/nan ms
"""
let nanPing = PingParser.measurement(from: nanPingOutput)
test.require(nanPing?.averageMilliseconds == nil, "NaN ping must be discarded without crashing")
test.require(nanPing?.packetLossPercent == 0, "valid packet loss should survive invalid timing statistics")
test.require(PingParser.averageMilliseconds(from: "round-trip min/avg/max/stddev = 1/inf/3/4 ms") == nil, "infinite ping must be discarded")
test.require(PingParser.averageMilliseconds(from: "round-trip min/avg/max/stddev = -1/-2/-3/-4 ms") == nil, "negative ping statistics must be discarded")
test.require(PingParser.measurement(from: "3 packets transmitted, 0 received, nan% packet loss") == nil, "NaN packet loss must be discarded")

let sshConfig = "user operator\nhostname 192.0.2.10\nport 22\n"
test.require(SSHConfigParser.hostname(from: sshConfig) == "192.0.2.10", "SSH config hostname should resolve the ping target")

let healthyNetwork = HostSnapshot(
    state: .online,
    pingMilliseconds: 50,
    pingJitterMilliseconds: 5,
    packetLossPercent: 0,
    latencyMilliseconds: 800,
    probeDurationMilliseconds: 1_900
)
let healthyDiagnosis = NetworkDiagnoser.diagnose(snapshot: healthyNetwork)
test.require(healthyDiagnosis?.level == .healthy, "healthy network should be distinguished from SSH and check work")
test.require(healthyDiagnosis?.detail.contains("SSH setup") == true, "healthy diagnosis should explain SSH overhead")

let lossyNetwork = HostSnapshot(state: .online, pingMilliseconds: 50, pingJitterMilliseconds: 5, packetLossPercent: 33.3)
test.require(NetworkDiagnoser.diagnose(snapshot: lossyNetwork)?.title == "Packet loss detected", "packet loss should take diagnostic priority")

let pingableSSHFailure = HostSnapshot(state: .unreachable, pingMilliseconds: 45, detail: "SSH timed out")
test.require(NetworkDiagnoser.diagnose(snapshot: pingableSSHFailure)?.title == "Network reachable, SSH failed", "pingable SSH failures should be attributed correctly")

let warningSnapshot = HostSnapshot(
    state: .online,
    pingMilliseconds: 250,
    pingJitterMilliseconds: 70,
    packetLossPercent: 2,
    latencyMilliseconds: 3_000,
    probeDurationMilliseconds: 6_000,
    detail: "Performance test"
)
let performanceWarnings = PerformanceEvaluator.warnings(
    snapshot: warningSnapshot,
    thresholds: .default
)
test.require(performanceWarnings.map(\.kind) == [.ping, .jitter, .packetLoss, .connectionReady, .fullProbe], "default thresholds should classify every timing layer")
test.require(PerformanceEvaluator.healthPenalty(for: performanceWarnings) == 30, "performance health penalty should be capped")
test.require(HealthScorer.score(snapshot: warningSnapshot, availability: 100) == 70, "performance warnings should reduce health")
test.require(PerformanceEvaluator.warnings(snapshot: pingableSSHFailure, thresholds: .default).isEmpty, "unreachable hosts should not duplicate performance warnings")

let relaxedThresholds = PerformanceThresholds(
    pingWarningMilliseconds: 500,
    jitterWarningMilliseconds: 100,
    packetLossWarningPercent: 5,
    connectionReadyWarningMilliseconds: 5_000,
    fullProbeWarningMilliseconds: 10_000
)
test.require(PerformanceEvaluator.warnings(snapshot: warningSnapshot, thresholds: relaxedThresholds).isEmpty, "custom thresholds should suppress lower values")
let thresholdRoundTrip = try decoder.decode(PerformanceThresholds.self, from: encoder.encode(relaxedThresholds))
test.require(thresholdRoundTrip == relaxedThresholds, "performance thresholds should persist through Codable")
let warningReport = FleetReportBuilder.build(hosts: [host], snapshots: [host.id: warningSnapshot])
test.require(warningReport.contains("Performance warning: High ping"), "diagnostic reports should include configured performance warnings")

let attentionOffline = FleetHost(id: "attention-offline", displayName: "Offline", systemImage: "desktopcomputer")
let attentionSlow = FleetHost(id: "attention-slow", displayName: "Slow", systemImage: "desktopcomputer")
let attentionService = FleetHost(id: "attention-service", displayName: "Service", systemImage: "desktopcomputer")
let attentionBoth = FleetHost(id: "attention-both", displayName: "Both", systemImage: "desktopcomputer")
let stoppedDocker = ServiceSnapshot(kind: .docker, state: .stopped, detail: "Stopped")
let attentionSnapshots = [
    attentionOffline.id: HostSnapshot(state: .unreachable),
    attentionSlow.id: HostSnapshot(state: .online, pingMilliseconds: 250),
    attentionService.id: HostSnapshot(state: .online, services: [stoppedDocker]),
    attentionBoth.id: HostSnapshot(state: .online, pingMilliseconds: 300, services: [stoppedDocker]),
]
let attentionSummary = FleetAttentionAnalyzer.summarize(
    hosts: [attentionOffline, attentionSlow, attentionService, attentionBoth],
    snapshots: attentionSnapshots,
    thresholds: .default
)
test.require(attentionSummary.onlineCount == 3, "attention summary should distinguish connected machines")
test.require(attentionSummary.unreachableCount == 1, "attention summary should count connection failures separately")
test.require(attentionSummary.performanceWarningCount == 2, "attention summary should count slow connected machines")
test.require(attentionSummary.serviceOrResourceAlertCount == 2, "attention summary should separate service and resource alerts")
test.require(attentionSummary.uniqueAttentionCount == 4, "overlapping warning categories should not double-count machines")
test.require(attentionSummary.compactDescription == "1 offline · 2 slow · 2 alerts", "menu status should retain every simultaneous attention category")
test.require(FleetAttentionSummary(onlineCount: 1, unreachableCount: 0, performanceWarningCount: 0, serviceOrResourceAlertCount: 0, uniqueAttentionCount: 0).compactDescription == nil, "healthy fleets should not add menu status text")
test.require(FleetAttentionAnalyzer.matches(snapshot: attentionSnapshots[attentionOffline.id]!, thresholds: .default, filter: .offline), "offline filter should include unreachable machines")
test.require(!FleetAttentionAnalyzer.matches(snapshot: attentionSnapshots[attentionOffline.id]!, thresholds: .default, filter: .online), "online filter should exclude unreachable machines")
test.require(FleetAttentionAnalyzer.matches(snapshot: attentionSnapshots[attentionSlow.id]!, thresholds: .default, filter: .slow), "slow filter should include connected performance warnings")
test.require(FleetAttentionAnalyzer.matches(snapshot: attentionSnapshots[attentionService.id]!, thresholds: .default, filter: .alerts), "alerts filter should include service and resource issues")
test.require(FleetAttentionAnalyzer.matches(snapshot: attentionSnapshots[attentionBoth.id]!, thresholds: .default, filter: .attention), "all-issues filter should include machines with overlapping warnings")
test.require(FleetAttentionAnalyzer.matches(snapshot: attentionSnapshots[attentionBoth.id]!, thresholds: .default, filter: .online), "connected machines with warnings should remain online")
test.require(!FleetAttentionAnalyzer.matches(snapshot: HostSnapshot(), thresholds: .default, filter: .attention), "checking machines should not appear as active issues")
let fleetFilterRoundTrip = try decoder.decode(FleetStatusFilter.self, from: encoder.encode(FleetStatusFilter.slow))
test.require(fleetFilterRoundTrip == .slow, "fleet status filters should persist through Codable")

let firstPerformanceCheck = PerformanceIncidentTracker.evaluate(previousCount: 0, hasWarnings: true)
test.require(firstPerformanceCheck == PerformanceIncidentDecision(newConsecutiveCount: 1, transition: .none), "first performance breach should remain unconfirmed")
let confirmedPerformanceCheck = PerformanceIncidentTracker.evaluate(previousCount: 1, hasWarnings: true)
test.require(confirmedPerformanceCheck.transition == .attention, "second consecutive breach should confirm a performance incident")
let sustainedPerformanceCheck = PerformanceIncidentTracker.evaluate(previousCount: 2, hasWarnings: true)
test.require(sustainedPerformanceCheck.transition == .none, "sustained breach should not duplicate incidents")
let recoveredPerformanceCheck = PerformanceIncidentTracker.evaluate(previousCount: 3, hasWarnings: false)
test.require(recoveredPerformanceCheck == PerformanceIncidentDecision(newConsecutiveCount: 0, transition: .recovered), "cleared sustained breach should record recovery")
test.require(IncidentKind.performanceAttention.category == .performance, "performance warning incidents should support category filtering")
test.require(IncidentKind.performanceRecovered.systemImage == "gauge.with.dots.needle.0percent", "performance recovery should expose its event symbol")
let performanceIncident = IncidentEvent(
    hostID: "example",
    kind: .performanceAttention,
    title: "Performance thresholds exceeded",
    detail: "High ping"
)
let performanceIncidentRoundTrip = try decoder.decode(IncidentEvent.self, from: encoder.encode(performanceIncident))
test.require(performanceIncidentRoundTrip.kind == .performanceAttention, "performance incidents should persist through JSONL encoding")

let oldDown = IncidentEvent(
    timestamp: windowNow.addingTimeInterval(-300),
    hostID: "offline",
    kind: .hostDown,
    title: "Offline is unreachable",
    detail: "First failure"
)
let latestDown = IncidentEvent(
    timestamp: windowNow.addingTimeInterval(-200),
    hostID: "offline",
    kind: .hostDown,
    title: "Offline is unreachable",
    detail: "Duplicate after restart"
)
let activePerformance = IncidentEvent(
    timestamp: windowNow.addingTimeInterval(-100),
    hostID: "slow",
    kind: .performanceAttention,
    title: "Performance thresholds exceeded",
    detail: "High ping"
)
let serviceAttention = IncidentEvent(
    timestamp: windowNow.addingTimeInterval(-90),
    hostID: "slow",
    kind: .serviceAttention,
    title: "Docker needs attention",
    detail: "Stopped"
)
let serviceRecovery = IncidentEvent(
    timestamp: windowNow.addingTimeInterval(-80),
    hostID: "slow",
    kind: .serviceRecovered,
    title: "Docker recovered",
    detail: "Active"
)
var activeState = ActiveIncidentState(
    events: [activePerformance, latestDown, serviceRecovery, oldDown, serviceAttention]
)
test.require(activeState.activeEvents.map(\.id) == [activePerformance.id, latestDown.id], "active incident reconstruction should keep only latest unresolved events")
test.require(activeState.hostDownHostIDs == ["offline"], "active outages should survive restart reconstruction")
test.require(activeState.performanceWarningHostIDs == ["slow"], "active performance warnings should survive restart reconstruction")
let recoveredDown = IncidentEvent(
    timestamp: windowNow,
    hostID: "offline",
    kind: .hostRecovered,
    title: "Offline recovered",
    detail: "Online"
)
activeState.apply(recoveredDown)
test.require(activeState.hostDownHostIDs.isEmpty, "recovery should clear persisted active outage state")
test.require(activeState.activeEvents == [activePerformance], "unrelated active warnings should remain after host recovery")

print("Fleetlight self-test: \(test.count) checks passed")
