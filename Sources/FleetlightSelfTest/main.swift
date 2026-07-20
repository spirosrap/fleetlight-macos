import Darwin
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

struct LegacyObserverStatusSnapshot: Decodable {
    let schemaVersion: Int
    let generatedAt: Date
    let appVersion: String
}

private let test = Harness()
test.require(FleetlightVersion.displayLabel(version: "1.32", build: "36") == "v1.32 (36)", "app version labels should show both release and build")
test.require(FleetlightVersion.displayLabel(version: "1.32", build: nil) == "v1.32", "app version labels should support a missing build")
test.require(FleetlightVersion.displayLabel(version: nil, build: "36") == "Build 36", "app version labels should support a build-only bundle")
test.require(FleetlightVersion.displayLabel(version: "  ", build: nil) == "Development", "app version labels should identify unbundled development runs")
test.require(FleetObserver.displayName(localizedName: " studio ", hostname: "provider.example.net") == "studio", "observer identity should prefer the localized Mac name")
test.require(FleetObserver.displayName(localizedName: nil, hostname: "workstation.example.net") == "workstation", "observer identity should shorten DNS hostnames")
test.require(FleetObserver.displayName(localizedName: " ", hostname: nil) == "This Mac", "observer identity should provide a safe fallback")
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
    RESTART_REQUIRED=required
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
test.require(verifiedSnapshot.linuxRestartRequired == true, "primary probes should carry the Linux restart flag")
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
let report = FleetReportBuilder.build(
    hosts: [host],
    snapshots: [host.id: verifiedSnapshot],
    observerName: "studio",
    appVersion: "v1.17 (21)"
)
test.require(report.contains("Observer: studio · Fleetlight v1.17 (21)"), "reports should identify their observer and Fleetlight build")
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

let appcastXML = """
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <title>26.708.10000</title>
      <sparkle:version>5220</sparkle:version>
      <sparkle:shortVersionString>26.708.10000</sparkle:shortVersionString>
    </item>
    <item>
      <sparkle:version>5211</sparkle:version>
      <sparkle:shortVersionString>26.707.62119</sparkle:shortVersionString>
    </item>
  </channel>
</rss>
"""
let latestAppRelease = CodexDesktopAppReleaseChecker.latestRelease(fromAppcastXML: appcastXML)
test.require(latestAppRelease == CodexDesktopAppRelease(version: "26.708.10000", build: "5220"), "Mac app release checks should use the newest appcast item")
test.require(CodexDesktopAppReleaseChecker.latestRelease(fromAppcastXML: "<rss></rss>") == nil, "invalid appcasts should not invent a release")
test.require(CodexDesktopAppReleaseChecker.state(snapshot: appSnapshot, latestRelease: latestAppRelease) == .updateAvailable, "older signed app builds should show an available update")
var currentAppSnapshot = appSnapshot
currentAppSnapshot.codexDesktopAppVersion = "26.708.10000"
currentAppSnapshot.codexDesktopAppBuild = "5220"
test.require(CodexDesktopAppReleaseChecker.state(snapshot: currentAppSnapshot, latestRelease: latestAppRelease) == .current, "matching signed app builds should be current")
test.require(CodexDesktopAppReleaseChecker.state(snapshot: HostSnapshot(state: .unreachable), latestRelease: latestAppRelease) == .offline, "unreachable Mac app hosts should remain offline")
test.require(CodexDesktopAppReleaseChecker.state(snapshot: HostSnapshot(state: .online), latestRelease: latestAppRelease) == .missing, "online hosts without the app should be missing")
let releaseReport = CodexDesktopAppReportBuilder.build(
    hosts: [appHost],
    snapshots: [appHost.id: appSnapshot],
    latestRelease: latestAppRelease,
    generatedAt: appCheckedAt
)
test.require(releaseReport.contains("Latest 26.708.10000 (build 5220)"), "Mac app reports should name the official latest release")
test.require(releaseReport.contains("update available"), "Mac app reports should mark outdated builds")

let freshnessNow = Date(timeIntervalSince1970: 10_000)
test.require(ReleaseCheckFreshness.label(checkedAt: nil, now: freshnessNow, failed: false) == "Not checked yet", "release freshness should identify missing checks")
test.require(ReleaseCheckFreshness.label(checkedAt: freshnessNow.addingTimeInterval(-45), now: freshnessNow, failed: false) == "Checked just now", "fresh release checks should read naturally")
test.require(ReleaseCheckFreshness.label(checkedAt: freshnessNow.addingTimeInterval(-125), now: freshnessNow, failed: true) == "Last attempt 2m ago", "failed release checks should label the attempt age")
test.require(ReleaseCheckFreshness.label(checkedAt: freshnessNow.addingTimeInterval(-7_200), now: freshnessNow, failed: false) == "Checked 2h ago", "older release checks should expose stale hours")

let cliUpdateAlert = CodexUpdateAlertPlanner.cliAlert(
    latestVersion: "0.145.0",
    updateCount: 2,
    lastNotifiedVersion: nil
)
test.require(cliUpdateAlert?.releaseKey == "0.145.0", "CLI update alerts should remember the published version")
test.require(cliUpdateAlert?.body.contains("2 machines") == true, "CLI update alerts should name the affected machine count")
test.require(CodexUpdateAlertPlanner.cliAlert(latestVersion: "0.145.0", updateCount: 2, lastNotifiedVersion: "0.145.0") == nil, "CLI update alerts should not repeat for the same release")
test.require(CodexUpdateAlertPlanner.cliAlert(latestVersion: "0.145.0", updateCount: 0, lastNotifiedVersion: nil) == nil, "CLI update alerts should require an outdated online machine")

let desktopUpdateAlert = CodexUpdateAlertPlanner.desktopAppAlert(
    latestRelease: latestAppRelease,
    updateCount: 1,
    lastNotifiedBuild: nil
)
test.require(desktopUpdateAlert?.releaseKey == "5220", "Mac app update alerts should deduplicate by signed build")
test.require(desktopUpdateAlert?.body.contains("1 Mac") == true, "Mac app update alerts should name the affected Mac count")
test.require(CodexUpdateAlertPlanner.desktopAppAlert(latestRelease: latestAppRelease, updateCount: 1, lastNotifiedBuild: "5220") == nil, "Mac app update alerts should not repeat for the same build")

let updateCenterSummary = CodexUpdateCenterSummary(cliUpdateCount: 2, desktopAppUpdateCount: 1)
test.require(updateCenterSummary.totalUpdateCount == 3, "the Update Center should combine CLI and Mac app actions")
test.require(updateCenterSummary.detail == "2 CLI · 1 Mac app", "the Update Center should keep update types visible")
test.require(updateCenterSummary.confirmationTitle == "Run 3 Codex updates?", "combined updates should use a clear confirmation title")
test.require(updateCenterSummary.confirmationDetail.contains("2 CLI updates, then 1 Mac app update"), "combined updates should explain their execution order")
let emptyUpdateCenter = CodexUpdateCenterSummary(cliUpdateCount: -1, desktopAppUpdateCount: 0)
test.require(emptyUpdateCenter.totalUpdateCount == 0 && emptyUpdateCenter.detail == "No updates available", "the Update Center should clamp invalid counts and explain an empty plan")
test.require(CodexUpdateCenterSummary(cliUpdateCount: 1, desktopAppUpdateCount: 0).confirmationTitle == "Run 1 Codex update?", "single combined actions should use singular wording")

let command = RemoteCommandBuilder.build(services: [.tailscale, .plex, .samba])
test.require(command.hasPrefix("printf 'FLEETLIGHT_OK"), "remote command should emit the verification marker before metrics")
test.require(command.contains("CODEX=%s"), "remote command should emit Codex CLI status")
test.require(command.contains("CODEX_APP_VERSION=%s"), "remote command should emit the signed Codex desktop app version on macOS")
test.require(command.contains("\"$HOME\"/.nvm/versions/node/*/bin/codex"), "remote command should inspect every NVM Codex install with a bounded shallow glob")
test.require(command.contains("setopt NULL_GLOB"), "remote command should make an unmatched NVM glob safe under zsh")
test.require(!command.contains("find \"$HOME/.nvm/versions/node\""), "routine probes should not recursively scan the NVM tree")
test.require(command.contains("!seen[$0]++"), "remote command should avoid probing duplicate Codex paths")
test.require(command.contains("SERVICE=tailscale"), "remote command should include Tailscale")
test.require(command.contains("SERVICE=plex"), "remote command should include Plex")
test.require(command.contains("SERVICE=samba"), "remote command should include Samba")
test.require(!command.contains("SERVICE=docker"), "remote command should exclude unconfigured services")
test.require(command.range(of: "SERVICE=tailscale")!.lowerBound < command.range(of: "os=$(uname -s)")!.lowerBound, "service checks should launch before slower platform facts")
test.require(command.hasSuffix("wait"), "remote command should wait for all concurrent fact and service checks")

let sshArguments = SSHCommandArguments.build(
    routeAlias: "example-route",
    command: "printf ready",
    connectTimeout: 5,
    serverAliveInterval: 15,
    serverAliveCountMax: 2
)
let sshOptions = sshArguments.joined(separator: " ")
test.require(Array(sshArguments.suffix(3)) == ["--", "example-route", "printf ready"], "pooled SSH arguments should terminate options and preserve the route and remote command")
test.require(sshOptions.contains("ControlMaster=auto") && sshOptions.contains("ControlPersist=120"), "routine SSH should reuse a short-lived connection pool")
test.require(sshOptions.contains("ForwardAgent=no") && sshOptions.contains("ClearAllForwardings=yes"), "background SSH pooling should disable inherited forwarding")
test.require(sshOptions.contains("ServerAliveInterval=15") && sshOptions.contains("ServerAliveCountMax=2"), "all pooled operations should share safe transport keepalives")
if let controlPath = SSHMultiplexing.controlPathPattern() {
    let expandedLength = controlPath.replacingOccurrences(of: "%C", with: String(repeating: "a", count: 40)).utf8.count
    test.require(expandedLength < 104, "the expanded SSH control socket path should remain below the macOS limit")
    let directory = URL(fileURLWithPath: controlPath).deletingLastPathComponent().path
    let attributes = try FileManager.default.attributesOfItem(atPath: directory)
    test.require(attributes[.type] as? FileAttributeType == .typeDirectory, "the SSH control path should use a real directory")
    test.require((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), "the SSH control directory should belong to the running user")
    test.require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "the SSH control directory should be private")
    let retireArguments = SSHMultiplexing.retireArguments(routeAlias: "example-route") ?? []
    test.require(retireArguments.contains("-O") && retireArguments.contains("exit"), "background validation should explicitly retire an existing pooled connection")
    test.require(Array(retireArguments.suffix(2)) == ["--", "example-route"], "pool retirement should preserve the configured route alias")
}
test.require(SSHMultiplexing.retirementSucceeded(CommandResult(exitCode: 0, stdout: "", stderr: "", elapsedMilliseconds: 4, timedOut: false)), "a confirmed control-master exit may establish a new validated pool")
test.require(!SSHMultiplexing.retirementSucceeded(CommandResult(exitCode: 255, stdout: "", stderr: "missing socket", elapsedMilliseconds: 4, timedOut: false)), "a failed control-master exit should force unpooled validation")
test.require(!SSHMultiplexing.retirementSucceeded(CommandResult(exitCode: -1, stdout: "", stderr: "", elapsedMilliseconds: 2_000, timedOut: true)), "a timed-out control-master exit should force unpooled validation")
let unpooledSSH = SSHCommandArguments.build(
    routeAlias: "example-route",
    command: "true",
    connectTimeout: 5,
    serverAliveInterval: 15,
    serverAliveCountMax: 2,
    multiplex: false
)
test.require(unpooledSSH.joined(separator: " ").contains("ControlMaster=no"), "unpooled operations should override user SSH multiplexing settings")
test.require(!unpooledSSH.joined(separator: " ").contains("ControlMaster=auto"), "unpooled operations should never join Fleetlight's connection pool")

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
test.require(
    CodexUpdateFailureReconciler.verifiedCurrentDetail(
        installedVersion: "0.144.3",
        latestVersion: "0.144.3",
        isOnline: true,
        releaseCheckFailed: false
    ) == "Codex 0.144.3 is current · prior update warning cleared",
    "a live current Codex version should clear a stale update failure"
)
test.require(
    CodexUpdateFailureReconciler.verifiedCurrentDetail(
        installedVersion: "0.144.2",
        latestVersion: "0.144.3",
        isOnline: true,
        releaseCheckFailed: false
    ) == nil,
    "an outdated Codex version must keep its update failure"
)
test.require(
    CodexUpdateFailureReconciler.verifiedCurrentDetail(
        installedVersion: "0.144.3",
        latestVersion: "0.144.3",
        isOnline: false,
        releaseCheckFailed: false
    ) == nil,
    "an offline machine must not clear an update failure"
)
test.require(
    CodexUpdateFailureReconciler.verifiedCurrentDetail(
        installedVersion: "0.144.3",
        latestVersion: "0.144.3",
        isOnline: true,
        releaseCheckFailed: true
    ) == nil,
    "a failed release check must not clear an update failure from stale release data"
)
let codexResultNow = Date(timeIntervalSince1970: 2_000_000)
test.require(
    CodexUpdateResultPresentation.summary(
        verifiedCount: 2,
        offlineCount: 0,
        failedCount: 1,
        pendingCount: 0,
        finishedAt: codexResultNow.addingTimeInterval(-125),
        now: codexResultNow
    ) == "Finished 2m ago · 2 verified · 1 failed",
    "completed Codex results should expose their age and outcome"
)
test.require(
    CodexUpdateResultPresentation.summary(
        verifiedCount: 0,
        offlineCount: 1,
        failedCount: 0,
        pendingCount: 0,
        finishedAt: nil,
        now: codexResultNow
    ) == "Previous result · 1 offline",
    "legacy Codex results without a completion time should still read as historical"
)
test.require(
    CodexUpdateResultPresentation.summary(
        verifiedCount: 0,
        offlineCount: 0,
        failedCount: 0,
        pendingCount: 0,
        finishedAt: codexResultNow,
        now: codexResultNow
    ) == nil,
    "empty Codex results should not create a historical banner"
)

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

let linuxCheckCommand = LinuxUpdateCheckCommandBuilder.build()
test.require(linuxCheckCommand.hasPrefix("printf 'FLEETLIGHT_LINUX_UPDATE_CHECK"), "Linux checks should emit a verification marker")
test.require(linuxCheckCommand.contains("refresh_metadata=1"), "manual Linux checks should refresh package metadata")
test.require(linuxCheckCommand.contains("apt-get update"), "Linux checks should refresh apt metadata before reporting availability")
test.require(linuxCheckCommand.contains("dpkg --audit"), "apt checks should detect incomplete package configuration even when no upgrades remain")
test.require(linuxCheckCommand.contains("STATUS:package-state-broken"), "broken apt package state should use a distinct structured status")
test.require(linuxCheckCommand.contains("ERROR:Package configuration is incomplete"), "apt package health failures should emit a concise privacy-safe error")
test.require(linuxCheckCommand.contains("snap refresh --list"), "Linux checks should include available Snap versions")
test.require(linuxCheckCommand.contains("flatpak remote-ls --updates"), "Linux checks should include available Flatpak versions")
test.require(linuxCheckCommand.contains("STATUS:package-check-failed"), "apt availability queries should fail closed instead of reporting a false current state")
test.require(linuxCheckCommand.contains("STATUS:snap-check-failed"), "Snap availability queries should fail closed instead of reporting zero updates")
test.require(linuxCheckCommand.contains("STATUS:flatpak-user-check-failed") && linuxCheckCommand.contains("STATUS:flatpak-system-check-failed"), "Flatpak availability queries should fail closed for both installations")
let recoveredLinuxCheckCommand = LinuxUpdateCheckCommandBuilder.build(refreshMetadata: false)
test.require(recoveredLinuxCheckCommand.contains("refresh_metadata=0"), "recovered machines should use a lightweight cached-metadata recheck")
test.require(recoveredLinuxCheckCommand.contains("if [ \"$refresh_metadata\" -eq 0 ]"), "lightweight recovery checks should not require package-manager privileges")
let normalizedRecoveredLinuxCheckCommand = recoveredLinuxCheckCommand.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
test.require(normalizedRecoveredLinuxCheckCommand.contains("if [ \"$refresh_metadata\" -eq 1 ]; then if ! run_privileged dpkg --audit"), "dpkg audits should run only during privileged full package checks")

let linuxUpdateCommand = LinuxUpdateCommandBuilder.build()
test.require(linuxUpdateCommand.hasPrefix("printf 'FLEETLIGHT_LINUX_UPDATE"), "Linux updates should emit a verification marker")
test.require(linuxUpdateCommand.contains("full-upgrade"), "apt updates should preserve the trusted fleet full-upgrade behavior")
test.require(linuxUpdateCommand.contains("dnf -y upgrade --refresh"), "Linux updates should support dnf")
test.require(linuxUpdateCommand.contains("pacman -Syu --noconfirm"), "Linux updates should support pacman")
test.require(linuxUpdateCommand.contains("snap refresh"), "Linux updates should refresh Snap packages")
test.require(linuxUpdateCommand.contains("flatpak update -y --noninteractive"), "Linux updates should refresh Flatpak packages")
test.require(linuxUpdateCommand.contains("emit_update_error dkms"), "apt updates should emit DKMS failure metadata before later package-manager output can bury the cause")
test.require(linuxUpdateCommand.contains("ERROR_KIND:%s"), "Linux update failure metadata should use a structured privacy-safe field")
test.require(!linuxUpdateCommand.contains("\nreboot") && !linuxUpdateCommand.contains("\nshutdown"), "Linux updates should never restart a machine automatically")

let linuxCheckedAt = Date(timeIntervalSince1970: 1_720_000_000)
let availableLinuxCheck = CommandResult(
    exitCode: 0,
    stdout: """
    FLEETLIGHT_LINUX_UPDATE_CHECK
    DISTRIBUTION:Ubuntu 24.04.2 LTS
    KERNEL:6.8.0-64-generic
    PACKAGE:curl|8.5.0-2ubuntu10.6|8.5.0-2ubuntu10.7
    PACKAGE:openssl|3.0.13-0ubuntu3.4|3.0.13-0ubuntu3.5
    PKG_MGR:apt
    PACKAGE_COUNT:2
    SECURITY_COUNT:1
    SNAP_COUNT:1
    FLATPAK_COUNT:1
    REBOOT:required
    STATUS:ok
    """,
    stderr: "",
    elapsedMilliseconds: 4_000,
    timedOut: false
)
let availableLinuxSnapshot = LinuxUpdateCheckParser.snapshot(from: availableLinuxCheck, checkedAt: linuxCheckedAt)
test.require(availableLinuxSnapshot.state == .updateAvailable, "pending Linux packages should be reported as updates available")
test.require(availableLinuxSnapshot.distribution == "Ubuntu 24.04.2 LTS", "Linux checks should retain the distribution version")
test.require(availableLinuxSnapshot.kernelVersion == "6.8.0-64-generic", "Linux checks should retain the current kernel version")
test.require(availableLinuxSnapshot.packageManager == "apt", "Linux checks should retain the detected package manager")
test.require(availableLinuxSnapshot.totalUpdateCount == 4, "Linux totals should include system, Snap, and Flatpak updates")
test.require(availableLinuxSnapshot.securityUpdateCount == 1, "Linux checks should retain security update counts where available")
test.require(availableLinuxSnapshot.availablePackages.first?.versionTransition == "8.5.0-2ubuntu10.6 → 8.5.0-2ubuntu10.7", "Linux checks should show installed and available package versions")
test.require(availableLinuxSnapshot.rebootRequired, "Linux checks should surface reboot-required state")
test.require(availableLinuxSnapshot.checkedAt == linuxCheckedAt, "Linux checks should retain freshness timestamps")
test.require(availableLinuxSnapshot.restartCheckedAt == linuxCheckedAt, "Linux package checks should timestamp their restart verification")
let reconciledLinuxSnapshot = availableLinuxSnapshot.replacingRebootRequired(false)
test.require(!reconciledLinuxSnapshot.rebootRequired, "live restart reconciliation should clear a stale restart flag")
test.require(reconciledLinuxSnapshot.totalUpdateCount == availableLinuxSnapshot.totalUpdateCount && reconciledLinuxSnapshot.checkedAt == availableLinuxSnapshot.checkedAt, "restart reconciliation should preserve package details and check freshness")
test.require(reconciledLinuxSnapshot.restartCheckedAt == linuxCheckedAt, "restart reconciliation should preserve an existing verification timestamp when no newer time is supplied")
test.require(LinuxRestartDetailReconciler.clearingRestartRequirement(from: "Verified current · restart required") == "Verified current", "restart reconciliation should clear stale update progress wording")
test.require(LinuxRestartDetailReconciler.clearingRestartRequirement(from: "Update completed · 2 still available · restart required") == "Update completed · 2 still available", "restart reconciliation should clear a restart suffix while preserving update detail")
test.require(LinuxRestartDetailReconciler.clearingRestartRequirement(from: "Restart verified · Linux still requests another restart") == "Restart verified · machine is back online", "restart reconciliation should correct a stale repeated-restart result")

let currentLinuxCheck = CommandResult(
    exitCode: 0,
    stdout: "FLEETLIGHT_LINUX_UPDATE_CHECK\nDISTRIBUTION:Fedora Linux 42\nKERNEL:6.15.4\nPKG_MGR:dnf\nPACKAGE_COUNT:0\nSECURITY_COUNT:0\nSNAP_COUNT:0\nFLATPAK_COUNT:0\nREBOOT:not-required\nSTATUS:ok\n",
    stderr: "",
    elapsedMilliseconds: 2_000,
    timedOut: false
)
let currentLinuxSnapshot = LinuxUpdateCheckParser.snapshot(from: currentLinuxCheck)
test.require(currentLinuxSnapshot.state == .current, "zero pending packages should report a current Linux machine")
let liveRestartCheckedAt = Date(timeIntervalSince1970: 1_720_000_600)
let newlyRequiredLinuxSnapshot = currentLinuxSnapshot.replacingRebootRequired(true, checkedAt: liveRestartCheckedAt)
test.require(newlyRequiredLinuxSnapshot.rebootRequired && newlyRequiredLinuxSnapshot.restartCheckedAt == liveRestartCheckedAt, "lightweight checks should detect and timestamp a new restart requirement")
test.require(newlyRequiredLinuxSnapshot.checkedAt == currentLinuxSnapshot.checkedAt && newlyRequiredLinuxSnapshot.totalUpdateCount == currentLinuxSnapshot.totalUpdateCount, "lightweight restart checks should not rewrite package freshness or counts")

let legacyLinuxSnapshotJSON = Data(#"{"state":"current","distribution":"Linux","kernelVersion":"6.8","packageManager":"apt","packageUpdateCount":0,"securityUpdateCount":0,"snapUpdateCount":0,"flatpakUpdateCount":0,"availablePackages":[],"rebootRequired":false,"checkedAt":0,"detail":"System packages are current"}"#.utf8)
let legacyLinuxSnapshot = try? JSONDecoder().decode(LinuxUpdateSnapshot.self, from: legacyLinuxSnapshotJSON)
test.require(legacyLinuxSnapshot != nil && legacyLinuxSnapshot?.restartCheckedAt == nil, "saved Linux snapshots from earlier Fleetlight versions should remain readable")

let offlineLinuxCheck = CommandResult(
    exitCode: 255,
    stdout: "",
    stderr: "ssh: connect to host example port 22: Connection timed out",
    elapsedMilliseconds: 12_000,
    timedOut: false
)
let offlineLinuxSnapshot = LinuxUpdateCheckParser.snapshot(from: offlineLinuxCheck)
test.require(offlineLinuxSnapshot.state == .offline, "SSH failures should remain distinct from Linux package failures")
test.require(
    LinuxUpdateCheckRetryPolicy.maximumRetryCount == 1
        && LinuxUpdateCheckRetryPolicy.shouldRetry(state: .offline, completedRetryCount: 0)
        && LinuxUpdateCheckRetryPolicy.shouldRetry(state: .failed, completedRetryCount: 0)
        && !LinuxUpdateCheckRetryPolicy.shouldRetry(state: .offline, completedRetryCount: 1)
        && !LinuxUpdateCheckRetryPolicy.shouldRetry(state: .current, completedRetryCount: 0)
        && !LinuxUpdateCheckRetryPolicy.shouldRetry(state: .updateAvailable, completedRetryCount: 0),
    "full Linux package checks should retry only one transient failed or offline result"
)

let privilegeLinuxCheck = CommandResult(
    exitCode: 4,
    stdout: "FLEETLIGHT_LINUX_UPDATE_CHECK\nDISTRIBUTION:Debian GNU/Linux 12\nKERNEL:6.1.0\nSTATUS:privilege-required\n",
    stderr: "",
    elapsedMilliseconds: 100,
    timedOut: false
)
test.require(LinuxUpdateCheckParser.snapshot(from: privilegeLinuxCheck).detail == "Passwordless sudo is required", "Linux checks should explain missing update privileges")

let brokenPackageStateLinuxCheck = CommandResult(
    exitCode: 7,
    stdout: "FLEETLIGHT_LINUX_UPDATE_CHECK\nDISTRIBUTION:Ubuntu 24.04 LTS\nKERNEL:7.0.0-28-generic\nPKG_MGR:apt\nSTATUS:package-state-broken\nERROR:Package configuration is incomplete\n",
    stderr: "",
    elapsedMilliseconds: 120,
    timedOut: false
)
let brokenPackageStateSnapshot = LinuxUpdateCheckParser.snapshot(from: brokenPackageStateLinuxCheck)
test.require(brokenPackageStateSnapshot.state == .failed, "incompletely configured apt packages should never be reported as current")
test.require(brokenPackageStateSnapshot.packageManager == "apt", "broken apt package state should retain the detected package manager")
test.require(brokenPackageStateSnapshot.detail == "Package configuration is incomplete · run sudo dpkg --configure -a", "broken apt package state should provide a concise recovery command")

let failedPackageQueryLinuxCheck = CommandResult(
    exitCode: 5,
    stdout: "FLEETLIGHT_LINUX_UPDATE_CHECK\nDISTRIBUTION:Ubuntu 24.04 LTS\nKERNEL:6.8.0\nPKG_MGR:apt\nSTATUS:package-check-failed\nERROR:APT update verification failed\n",
    stderr: "",
    elapsedMilliseconds: 100,
    timedOut: false
)
test.require(LinuxUpdateCheckParser.snapshot(from: failedPackageQueryLinuxCheck).detail == "APT update verification failed", "failed apt availability queries should remain failed and actionable")

let failedSnapQueryLinuxCheck = CommandResult(
    exitCode: 5,
    stdout: "FLEETLIGHT_LINUX_UPDATE_CHECK\nDISTRIBUTION:Ubuntu 24.04 LTS\nKERNEL:6.8.0\nPKG_MGR:apt\nSTATUS:snap-check-failed\nERROR:Snap update verification failed\n",
    stderr: "",
    elapsedMilliseconds: 100,
    timedOut: false
)
test.require(LinuxUpdateCheckParser.snapshot(from: failedSnapQueryLinuxCheck).detail == "Snap update verification failed", "failed Snap queries should never clear a saved update failure")

let failedFlatpakQueryLinuxCheck = CommandResult(
    exitCode: 5,
    stdout: "FLEETLIGHT_LINUX_UPDATE_CHECK\nDISTRIBUTION:Ubuntu 24.04 LTS\nKERNEL:6.8.0\nPKG_MGR:apt\nSTATUS:flatpak-system-check-failed\nERROR:Flatpak system update verification failed\n",
    stderr: "",
    elapsedMilliseconds: 100,
    timedOut: false
)
test.require(LinuxUpdateCheckParser.snapshot(from: failedFlatpakQueryLinuxCheck).detail == "Flatpak system update verification failed", "failed Flatpak queries should never clear a saved update failure")

let linuxUpdateHosts = [
    FleetHost(id: "updates", displayName: "Updates", systemImage: "server.rack", supportsLinuxUpdates: true),
    FleetHost(id: "current-linux", displayName: "Current", systemImage: "server.rack", supportsLinuxUpdates: true),
    FleetHost(id: "offline-linux", displayName: "Offline", systemImage: "server.rack", supportsLinuxUpdates: true),
]
let linuxSummary = LinuxUpdateAnalyzer.summarize(
    hosts: linuxUpdateHosts,
    snapshots: [
        "updates": availableLinuxSnapshot,
        "current-linux": currentLinuxSnapshot,
        "offline-linux": offlineLinuxSnapshot,
    ]
)
test.require(linuxSummary == LinuxUpdateSummary(currentCount: 1, updateAvailableCount: 1, offlineCount: 1, unavailableCount: 0, totalPendingUpdates: 4), "Linux update summaries should count each machine and pending package exactly once")
test.require(LinuxUpdateAnalyzer.availableHosts(hosts: linuxUpdateHosts, snapshots: ["updates": availableLinuxSnapshot]).map(\.id) == ["updates"], "sequential Linux updates should target only machines with known updates")
test.require(LinuxUpdateAnalyzer.restartRequiredHosts(hosts: linuxUpdateHosts, snapshots: ["updates": availableLinuxSnapshot, "current-linux": currentLinuxSnapshot]).map(\.id) == ["updates"], "Linux restarts should target only machines reporting restart required")

var refreshRequestQueue = RefreshRequestQueue()
test.require(!refreshRequestQueue.isQueued, "refresh requests should not start queued")
test.require(refreshRequestQueue.request(isBlocked: false) == .startNow, "unblocked refresh requests should start immediately")
test.require(!refreshRequestQueue.isQueued, "an immediate refresh should not leave queued work")
test.require(refreshRequestQueue.request(isBlocked: true) == .queued, "blocked refresh requests should be queued")
test.require(refreshRequestQueue.isQueued, "queued refresh state should be observable")
test.require(refreshRequestQueue.request(isBlocked: true) == .alreadyQueued, "repeated blocked requests should coalesce")
test.require(!refreshRequestQueue.takeIfReady(isBlocked: true) && refreshRequestQueue.isQueued, "queued refreshes should remain pending while work is blocked")
test.require(refreshRequestQueue.takeIfReady(isBlocked: false), "a queued refresh should become runnable when blocking work finishes")
test.require(!refreshRequestQueue.isQueued && !refreshRequestQueue.takeIfReady(isBlocked: false), "a queued refresh should be consumed exactly once")
var staleRefreshRequestQueue = RefreshRequestQueue(isQueued: true)
test.require(staleRefreshRequestQueue.request(isBlocked: false) == .startNow && !staleRefreshRequestQueue.isQueued, "a direct ready request should consume stale queued state without scheduling a duplicate")

let recoveryNow = Date(timeIntervalSince1970: 1_720_000_900)
let recoverableOfflineSnapshot = LinuxUpdateSnapshot(
    state: .offline,
    checkedAt: recoveryNow.addingTimeInterval(-1_000),
    detail: "SSH timed out"
)
let recoveryHostSnapshots = [
    "updates": HostSnapshot(state: .online),
    "current-linux": HostSnapshot(state: .online),
    "offline-linux": HostSnapshot(state: .online),
]
test.require(
    LinuxUpdateRecoveryPlanner.hostsToRecheck(
        hosts: linuxUpdateHosts,
        hostSnapshots: recoveryHostSnapshots,
        updateSnapshots: [
            "updates": availableLinuxSnapshot,
            "current-linux": currentLinuxSnapshot,
            "offline-linux": recoverableOfflineSnapshot,
        ],
        now: recoveryNow,
        retryInterval: 900
    ).map(\.id) == ["offline-linux"],
    "an old offline package result should recheck automatically after normal monitoring proves the machine is online"
)
test.require(
    LinuxUpdateRecoveryPlanner.hostsToRecheck(
        hosts: linuxUpdateHosts,
        hostSnapshots: ["offline-linux": HostSnapshot(state: .unreachable)],
        updateSnapshots: ["offline-linux": recoverableOfflineSnapshot],
        now: recoveryNow,
        retryInterval: 900
    ).isEmpty,
    "offline machines should not run recovery package checks"
)
test.require(
    LinuxUpdateRecoveryPlanner.hostsToRecheck(
        hosts: linuxUpdateHosts,
        hostSnapshots: recoveryHostSnapshots,
        updateSnapshots: ["offline-linux": LinuxUpdateSnapshot(state: .offline, checkedAt: recoveryNow.addingTimeInterval(-60))],
        now: recoveryNow,
        retryInterval: 900
    ).isEmpty,
    "recent failed package checks should honor the retry cooldown"
)

let restartSummaryNow = Date(timeIntervalSince1970: 1_720_001_000)
let restartSummaryHosts = [
    FleetHost(id: "recent", displayName: "Recent", systemImage: "server.rack", supportsLinuxUpdates: true),
    FleetHost(id: "required", displayName: "Required", systemImage: "server.rack", supportsLinuxUpdates: true),
    FleetHost(id: "stale", displayName: "Stale", systemImage: "server.rack", supportsLinuxUpdates: true),
    FleetHost(id: "unverified", displayName: "Unverified", systemImage: "server.rack", supportsLinuxUpdates: true),
]
let restartVerificationSummary = LinuxRestartVerificationAnalyzer.summarize(
    hosts: restartSummaryHosts,
    snapshots: [
        "recent": LinuxUpdateSnapshot(state: .current, restartCheckedAt: restartSummaryNow.addingTimeInterval(-30)),
        "required": LinuxUpdateSnapshot(state: .current, rebootRequired: true, restartCheckedAt: restartSummaryNow.addingTimeInterval(-60)),
        "stale": LinuxUpdateSnapshot(state: .current, restartCheckedAt: restartSummaryNow.addingTimeInterval(-600)),
    ],
    now: restartSummaryNow,
    freshnessInterval: 300
)
test.require(restartVerificationSummary == LinuxRestartVerificationSummary(recentCount: 2, staleCount: 1, unverifiedCount: 1, requiredCount: 1, lastVerifiedAt: restartSummaryNow.addingTimeInterval(-30)), "restart verification summaries should separate recent, stale, unverified, and required machines")

let observerGeneratedAt = Date(timeIntervalSince1970: 1_720_001_100)
let observerStatus = ObserverStatusSnapshot(
    generatedAt: observerGeneratedAt,
    appVersion: "v1.32 (36)",
    linuxHostCount: 4,
    restartRequiredCount: 1,
    recentVerificationCount: 4,
    staleVerificationCount: 0,
    unverifiedCount: 0
)
let observerStatusData = try! JSONEncoder().encode(observerStatus)
let decodedObserverStatus = try! JSONDecoder().decode(ObserverStatusSnapshot.self, from: observerStatusData)
test.require(decodedObserverStatus == observerStatus && decodedObserverStatus.maintenanceActivity == nil, "legacy observer snapshots should decode without a maintenance field")
let observerCommand = ObserverStatusCommandBuilder.build()
test.require(observerCommand.contains("FLEETLIGHT_OBSERVER_STATUS") && observerCommand.contains("observer-status.json"), "observer checks should use a verified aggregate status file")
test.require(!observerCommand.contains("fleet.json") && !observerCommand.contains(".ssh"), "observer status checks should not read fleet configuration or SSH credentials")
let observerAvailableResult = CommandResult(
    exitCode: 0,
    stdout: "FLEETLIGHT_OBSERVER_STATUS\nSTATUS:available\n\(String(data: observerStatusData, encoding: .utf8)!)\n",
    stderr: "",
    elapsedMilliseconds: 20,
    timedOut: false
)
test.require(ObserverStatusParser.outcome(from: observerAvailableResult).snapshot == observerStatus, "observer status responses should decode verified snapshots")
let observerMissingResult = CommandResult(exitCode: 4, stdout: "FLEETLIGHT_OBSERVER_STATUS\nSTATUS:missing\n", stderr: "", elapsedMilliseconds: 20, timedOut: false)
test.require(ObserverStatusParser.outcome(from: observerMissingResult).state == .missing, "observers that have not published yet should be distinct from offline observers")
let observerOfflineResult = CommandResult(exitCode: 255, stdout: "", stderr: "unreachable", elapsedMilliseconds: 20, timedOut: false)
test.require(ObserverStatusParser.outcome(from: observerOfflineResult).state == .offline, "unreachable observers should remain explicit")
let observerDiagnostic = ObserverStatusDiagnosticBuilder.build(
    from: ObserverStatusFetchOutcome(state: .available, snapshot: observerStatus, detail: "Available")
)
test.require(observerDiagnostic.statusTitle == "Reporting" && observerDiagnostic.appVersion == "v1.32 (36)", "observer details should expose the reporting Fleetlight version")
test.require(observerDiagnostic.restartDescription == "1 restart required", "observer details should use a readable singular restart count")
test.require(observerDiagnostic.verificationDescription == "4 Linux · 4 recent · 0 stale · 0 unverified", "observer details should summarize verification coverage")
let waitingObserverDiagnostic = ObserverStatusDiagnosticBuilder.build(from: nil)
test.require(waitingObserverDiagnostic.statusTitle == "Waiting" && waitingObserverDiagnostic.generatedAt == nil, "observer details should explain the pre-check state")
let offlineObserverDiagnostic = ObserverStatusDiagnosticBuilder.build(from: ObserverStatusFetchOutcome(state: .offline, detail: "Observer is unreachable"))
test.require(offlineObserverDiagnostic.statusTitle == "Offline" && offlineObserverDiagnostic.detail == "Observer is unreachable", "observer details should preserve an offline explanation")

let matchingObserver = ObserverStatusSnapshot(
    generatedAt: observerGeneratedAt.addingTimeInterval(5),
    appVersion: observerStatus.appVersion,
    linuxHostCount: observerStatus.linuxHostCount,
    restartRequiredCount: observerStatus.restartRequiredCount,
    recentVerificationCount: observerStatus.recentVerificationCount,
    staleVerificationCount: observerStatus.staleVerificationCount,
    unverifiedCount: observerStatus.unverifiedCount
)
let maintenanceObserver = ObserverStatusSnapshot(
    generatedAt: observerGeneratedAt.addingTimeInterval(350),
    appVersion: matchingObserver.appVersion,
    linuxHostCount: matchingObserver.linuxHostCount,
    restartRequiredCount: 2,
    recentVerificationCount: 2,
    staleVerificationCount: 1,
    unverifiedCount: 1,
    maintenanceActivity: .updatingLinux
)
let maintenanceObserverData = try! JSONEncoder().encode(maintenanceObserver)
test.require(try! JSONDecoder().decode(ObserverStatusSnapshot.self, from: maintenanceObserverData) == maintenanceObserver, "observer snapshots should preserve active maintenance without exposing fleet details")
let legacyMaintenanceDecode = try! JSONDecoder().decode(LegacyObserverStatusSnapshot.self, from: maintenanceObserverData)
test.require(legacyMaintenanceDecode.schemaVersion == 1 && legacyMaintenanceDecode.generatedAt == maintenanceObserver.generatedAt && legacyMaintenanceDecode.appVersion == maintenanceObserver.appVersion, "older observer decoders should ignore the additive maintenance field")
let maintenanceDiagnostic = ObserverStatusDiagnosticBuilder.build(
    from: ObserverStatusFetchOutcome(state: .available, snapshot: maintenanceObserver, detail: "Available")
)
test.require(maintenanceDiagnostic.statusTitle == "Updating Linux", "observer details should identify active Linux maintenance")
let observerOutcomes = [
    "first": ObserverStatusFetchOutcome(state: .available, snapshot: observerStatus, detail: "Available"),
    "second": ObserverStatusFetchOutcome(state: .available, snapshot: matchingObserver, detail: "Available"),
]
test.require(ObserverStatusRefreshPolicy.heartbeatInterval == 60, "observer heartbeats should remain frequent enough to detect local status changes")
test.require(
    ObserverStatusRefreshPolicy.remoteCacheInterval(
        expectedCount: 2,
        outcomes: observerOutcomes,
        now: observerGeneratedAt.addingTimeInterval(300),
        freshnessInterval: 300
    ) == 240,
    "complete observer results should use the healthy remote cache interval while every snapshot is fresh"
)
test.require(
    ObserverStatusRefreshPolicy.remoteCacheInterval(
        expectedCount: 3,
        outcomes: observerOutcomes,
        now: observerGeneratedAt.addingTimeInterval(30),
        freshnessInterval: 300
    ) == 45,
    "missing observer results should use the recovery cache interval"
)
test.require(
    ObserverStatusRefreshPolicy.remoteCacheInterval(
        expectedCount: 2,
        outcomes: [
            "first": observerOutcomes["first"]!,
            "second": ObserverStatusFetchOutcome(state: .offline, detail: "Observer is unreachable"),
        ],
        now: observerGeneratedAt.addingTimeInterval(30),
        freshnessInterval: 300
    ) == 45,
    "unavailable observer results should use the recovery cache interval"
)
test.require(
    ObserverStatusRefreshPolicy.remoteCacheInterval(
        expectedCount: 2,
        outcomes: observerOutcomes,
        now: observerGeneratedAt.addingTimeInterval(301),
        freshnessInterval: 300
    ) == 45,
    "stale observer snapshots should use the recovery cache interval"
)
test.require(
    ObserverStatusRefreshPolicy.remoteCacheInterval(
        expectedCount: 1,
        outcomes: ["first": ObserverStatusFetchOutcome(state: .available, detail: "Incomplete")],
        now: observerGeneratedAt,
        freshnessInterval: 300
    ) == 45,
    "available observer results without a snapshot should use the recovery cache interval"
)
test.require(
    ObserverStatusRefreshPolicy.remoteCacheInterval(
        expectedCount: 1,
        outcomes: ["first": ObserverStatusFetchOutcome(state: .available, snapshot: maintenanceObserver, detail: "Available")],
        now: observerGeneratedAt.addingTimeInterval(360),
        freshnessInterval: 300
    ) == 45,
    "active observer maintenance should use the recovery cache interval so completion is fetched promptly"
)
let mismatchedVersionObserver = ObserverStatusSnapshot(
    generatedAt: matchingObserver.generatedAt,
    appVersion: "v1.31 (35)",
    linuxHostCount: matchingObserver.linuxHostCount,
    restartRequiredCount: matchingObserver.restartRequiredCount,
    recentVerificationCount: matchingObserver.recentVerificationCount,
    staleVerificationCount: matchingObserver.staleVerificationCount,
    unverifiedCount: matchingObserver.unverifiedCount
)
test.require(
    ObserverStatusRefreshPolicy.remoteCacheInterval(
        expectedCount: 2,
        outcomes: [
            "first": observerOutcomes["first"]!,
            "second": ObserverStatusFetchOutcome(state: .available, snapshot: mismatchedVersionObserver, detail: "Available"),
        ],
        now: observerGeneratedAt.addingTimeInterval(30),
        freshnessInterval: 300
    ) == 45,
    "observer disagreements should use the recovery cache interval so rolling upgrades clear promptly"
)
let observerConsistency = ObserverConsistencyAnalyzer.summarize(
    expectedObserverIDs: ["first", "second"],
    outcomes: observerOutcomes,
    now: observerGeneratedAt.addingTimeInterval(30),
    freshnessInterval: 300
)
test.require(observerConsistency.state == .consistent && observerConsistency.detail.contains("2 observers agree"), "fresh matching observers should report agreement")
let maintenanceConsistency = ObserverConsistencyAnalyzer.summarize(
    expectedObserverIDs: ["first", "second"],
    outcomes: [
        "first": observerOutcomes["first"]!,
        "second": ObserverStatusFetchOutcome(state: .available, snapshot: maintenanceObserver, detail: "Available"),
    ],
    now: observerGeneratedAt.addingTimeInterval(360),
    freshnessInterval: 300
)
test.require(maintenanceConsistency.state == .maintenance && maintenanceConsistency.detail.contains("comparison resumes automatically"), "fresh Linux maintenance should override a stale peer and transient restart disagreement")
let staleMaintenanceObserver = ObserverStatusSnapshot(
    generatedAt: observerGeneratedAt,
    appVersion: maintenanceObserver.appVersion,
    linuxHostCount: maintenanceObserver.linuxHostCount,
    restartRequiredCount: maintenanceObserver.restartRequiredCount,
    recentVerificationCount: maintenanceObserver.recentVerificationCount,
    staleVerificationCount: maintenanceObserver.staleVerificationCount,
    unverifiedCount: maintenanceObserver.unverifiedCount,
    maintenanceActivity: .updatingLinux
)
let freshIdleObserver = ObserverStatusSnapshot(
    generatedAt: observerGeneratedAt.addingTimeInterval(350),
    appVersion: observerStatus.appVersion,
    linuxHostCount: observerStatus.linuxHostCount,
    restartRequiredCount: observerStatus.restartRequiredCount,
    recentVerificationCount: observerStatus.recentVerificationCount,
    staleVerificationCount: observerStatus.staleVerificationCount,
    unverifiedCount: observerStatus.unverifiedCount
)
let expiredMaintenanceConsistency = ObserverConsistencyAnalyzer.summarize(
    expectedObserverIDs: ["first", "second"],
    outcomes: [
        "first": ObserverStatusFetchOutcome(state: .available, snapshot: staleMaintenanceObserver, detail: "Available"),
        "second": ObserverStatusFetchOutcome(state: .available, snapshot: freshIdleObserver, detail: "Available"),
    ],
    now: observerGeneratedAt.addingTimeInterval(360),
    freshnessInterval: 300
)
test.require(expiredMaintenanceConsistency.state == .stale, "an expired maintenance report should remain stale when its peer is fresh")
let disagreeingObserver = ObserverStatusSnapshot(
    generatedAt: matchingObserver.generatedAt,
    appVersion: matchingObserver.appVersion,
    linuxHostCount: matchingObserver.linuxHostCount,
    restartRequiredCount: 0,
    recentVerificationCount: matchingObserver.recentVerificationCount,
    staleVerificationCount: matchingObserver.staleVerificationCount,
    unverifiedCount: matchingObserver.unverifiedCount
)
let disagreement = ObserverConsistencyAnalyzer.summarize(
    expectedObserverIDs: ["first", "second"],
    outcomes: [
        "first": observerOutcomes["first"]!,
        "second": ObserverStatusFetchOutcome(state: .available, snapshot: disagreeingObserver, detail: "Available"),
    ],
    now: observerGeneratedAt.addingTimeInterval(30),
    freshnessInterval: 300
)
test.require(disagreement.state == .disagreement && disagreement.detail.contains("0 vs 1"), "different restart counts should be called out as observer disagreement")
let staleConsistency = ObserverConsistencyAnalyzer.summarize(
    expectedObserverIDs: ["first", "second"],
    outcomes: observerOutcomes,
    now: observerGeneratedAt.addingTimeInterval(600),
    freshnessInterval: 300
)
test.require(staleConsistency.state == .stale, "expired observer reports should not be presented as agreement")
let unavailableConsistency = ObserverConsistencyAnalyzer.summarize(
    expectedObserverIDs: ["first", "second"],
    outcomes: ["first": observerOutcomes["first"]!],
    now: observerGeneratedAt.addingTimeInterval(30),
    freshnessInterval: 300
)
test.require(unavailableConsistency.state == .unavailable, "missing observer reports should stay visible")
test.require(ObserverConsistencyAnalyzer.summarize(expectedObserverIDs: ["first"], outcomes: ["first": observerOutcomes["first"]!]).state == .insufficient, "single-Mac fleets should explain that comparison needs two observers")

let successfulLinuxUpdate = CommandResult(
    exitCode: 0,
    stdout: "FLEETLIGHT_LINUX_UPDATE\nPKG_MGR:apt\nREBOOT:required\nUPDATE:ok\n",
    stderr: "",
    elapsedMilliseconds: 30_000,
    timedOut: false
)
let successfulLinuxOutcome = LinuxUpdateParser.outcome(from: successfulLinuxUpdate)
test.require(successfulLinuxOutcome.status == .succeeded && successfulLinuxOutcome.rebootRequired, "verified Linux update commands should retain reboot state")
test.require(successfulLinuxOutcome.detail.contains("restart required"), "successful Linux updates should explain when a restart remains")

let failedLinuxUpdate = CommandResult(
    exitCode: 4,
    stdout: "FLEETLIGHT_LINUX_UPDATE\nUPDATE:privilege-required\n",
    stderr: "",
    elapsedMilliseconds: 100,
    timedOut: false
)
test.require(LinuxUpdateParser.outcome(from: failedLinuxUpdate).detail == "Passwordless sudo is required", "Linux update failures should explain missing privileges")

let failedDKMSLinuxUpdate = CommandResult(
    exitCode: 1,
    stdout: """
    FLEETLIGHT_LINUX_UPDATE
    PKG_MGR:apt
    Error! Bad return status for module build on kernel: 7.0.0-28-generic (x86_64)
    Consult /var/lib/dkms/rtl8852bu/1.19.14-127/build/make.log for more information.
    dkms autoinstall on 7.0.0-28-generic/x86_64 failed for rtl8852bu(10)
    dpkg: error processing package linux-image-7.0.0-28-generic (--configure):
    UPDATE:failed
    """,
    stderr: "",
    elapsedMilliseconds: 60_000,
    timedOut: false
)
test.require(LinuxUpdateParser.outcome(from: failedDKMSLinuxUpdate).detail == "Kernel module rtl8852bu failed to build (DKMS)", "DKMS failures should identify the safe module name instead of collapsing to a generic update failure")

let structuredDKMSLinuxUpdate = CommandResult(
    exitCode: 1,
    stdout: "FLEETLIGHT_LINUX_UPDATE\nERROR_KIND:dkms\nERROR_ID:rtl8852bu\nPKG_MGR:apt\nLater Flatpak output\nUPDATE:failed\n",
    stderr: "",
    elapsedMilliseconds: 60_000,
    timedOut: false
)
test.require(LinuxUpdateParser.outcome(from: structuredDKMSLinuxUpdate).detail == "Kernel module rtl8852bu failed to build (DKMS)", "structured apt failure metadata should preserve the root cause after later update output")

let failedDPKGLinuxUpdate = CommandResult(
    exitCode: 1,
    stdout: "FLEETLIGHT_LINUX_UPDATE\nPKG_MGR:apt\ndpkg: error processing package linux-image-generic (--configure):\nUPDATE:failed\n",
    stderr: "",
    elapsedMilliseconds: 1_000,
    timedOut: false
)
test.require(LinuxUpdateParser.outcome(from: failedDPKGLinuxUpdate).detail == "Package linux-image-generic could not be configured (dpkg)", "dpkg failures should retain a safe actionable package name")

let linuxRestartRequirementCommand = LinuxRestartRequirementCommandBuilder.build()
test.require(linuxRestartRequirementCommand.hasPrefix("printf 'FLEETLIGHT_LINUX_RESTART_REQUIREMENT"), "restart requirement checks should emit a verification marker")
test.require(linuxRestartRequirementCommand.contains("/var/run/reboot-required"), "restart requirement checks should inspect the live Linux reboot flag")
test.require(!linuxRestartRequirementCommand.contains("sudo"), "restart requirement checks should not require elevated privileges")

let liveRestartRequired = CommandResult(
    exitCode: 0,
    stdout: "FLEETLIGHT_LINUX_RESTART_REQUIREMENT\nRESTART_REQUIREMENT:required\n",
    stderr: "",
    elapsedMilliseconds: 30,
    timedOut: false
)
test.require(LinuxRestartRequirementParser.outcome(from: liveRestartRequired).status == .required, "live restart checks should retain a required flag")

let liveRestartCleared = CommandResult(
    exitCode: 0,
    stdout: "FLEETLIGHT_LINUX_RESTART_REQUIREMENT\nRESTART_REQUIREMENT:not-required\n",
    stderr: "",
    elapsedMilliseconds: 30,
    timedOut: false
)
test.require(LinuxRestartRequirementParser.outcome(from: liveRestartCleared).status == .notRequired, "live restart checks should detect that a reboot flag cleared")

let offlineRestartRequirement = CommandResult(
    exitCode: 255,
    stdout: "",
    stderr: "ssh: connect to host example port 22: Connection timed out",
    elapsedMilliseconds: 8_000,
    timedOut: false
)
test.require(LinuxRestartRequirementParser.outcome(from: offlineRestartRequirement).status == .offline, "offline restart checks should not clear cached state")

let linuxRestartCommand = LinuxRestartCommandBuilder.build()
test.require(linuxRestartCommand.hasPrefix("printf 'FLEETLIGHT_LINUX_RESTART"), "Linux restarts should emit a verification marker")
test.require(linuxRestartCommand.contains("sudo -n"), "Linux restarts should require non-interactive privilege escalation")
test.require(linuxRestartCommand.contains("sleep 2"), "Linux restarts should acknowledge the request before disconnecting SSH")
test.require(linuxRestartCommand.contains("systemctl reboot"), "Linux restarts should prefer systemd where available")
test.require(linuxRestartCommand.contains("shutdown -r now"), "Linux restarts should include a portable shutdown fallback")

let scheduledLinuxRestart = CommandResult(
    exitCode: 0,
    stdout: "FLEETLIGHT_LINUX_RESTART\nBOOT_BEFORE:2026-07-15 07:00:00\nRESTART:scheduled\n",
    stderr: "",
    elapsedMilliseconds: 80,
    timedOut: false
)
let scheduledLinuxRestartOutcome = LinuxRestartParser.outcome(from: scheduledLinuxRestart)
test.require(scheduledLinuxRestartOutcome.status == .scheduled, "acknowledged Linux restarts should be treated as scheduled")
test.require(scheduledLinuxRestartOutcome.bootDescriptionBeforeRestart == "2026-07-15 07:00:00", "Linux restart verification should retain the pre-restart boot time")

let disconnectedAfterSchedulingRestart = CommandResult(
    exitCode: 255,
    stdout: "FLEETLIGHT_LINUX_RESTART\nBOOT_BEFORE:2026-07-15 07:00:00\nRESTART:scheduled\n",
    stderr: "Connection to example closed by remote host.",
    elapsedMilliseconds: 2_100,
    timedOut: false
)
test.require(LinuxRestartParser.outcome(from: disconnectedAfterSchedulingRestart).status == .scheduled, "SSH closing after restart acknowledgement should not turn a scheduled restart into a failure")

let unauthorizedLinuxRestart = CommandResult(
    exitCode: 4,
    stdout: "FLEETLIGHT_LINUX_RESTART\nRESTART:privilege-required\n",
    stderr: "",
    elapsedMilliseconds: 50,
    timedOut: false
)
test.require(LinuxRestartParser.outcome(from: unauthorizedLinuxRestart).detail == "Passwordless sudo is required", "Linux restart failures should explain missing privileges")


let codexDesktopAppCommand = CodexDesktopAppUpdateCommandBuilder.build()
test.require(codexDesktopAppCommand.hasPrefix("printf 'FLEETLIGHT_CODEX_APP_UPDATE"), "Codex app updater should emit a verification marker")
test.require(codexDesktopAppCommand.contains("com.openai.codex"), "Codex app updater should verify the OpenAI bundle identifier")
test.require(codexDesktopAppCommand.contains("persistent.oaistatic.com/codex-app-prod/appcast.xml"), "Codex app updater should use the official update feed")
test.require(codexDesktopAppCommand.contains("TeamIdentifier") && codexDesktopAppCommand.contains("2DC432GLL2"), "Codex app updater should verify OpenAI's signing team")
test.require(codexDesktopAppCommand.contains("codesign --verify --deep --strict"), "Codex app updater should verify the downloaded app before installation")
test.require(codexDesktopAppCommand.contains("Fleetlight-ChatGPT-backup"), "Codex app updater should preserve a rollback copy during installation")
test.require(!codexDesktopAppCommand.contains("System Events"), "Codex app updater should not require macOS UI automation permission")
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

let invalidSignatureCodexDesktopApp = CommandResult(
    exitCode: 3,
    stdout: "FLEETLIGHT_CODEX_APP_UPDATE\nBEFORE_VERSION:26.707.62119\nBEFORE_BUILD:5211\nUPDATE:signature-invalid\nVERIFY:failed\n",
    stderr: "",
    elapsedMilliseconds: 400,
    timedOut: false
)
test.require(
    CodexDesktopAppUpdateParser.outcome(from: invalidSignatureCodexDesktopApp).detail.contains("verified"),
    "invalid Codex app downloads should report a verification failure"
)

let defaultHost = FleetHost.defaults.first!
test.require(FleetHost.defaults.count == 1, "the public default fleet should contain only this Mac")
test.require(defaultHost.id == "local" && defaultHost.isLocal, "the public default should not contain a private SSH target")
test.require(defaultHost.services.isEmpty, "the public default should not reveal configured services")
test.require(defaultHost.supportsCodexDesktopApp, "the safe local default should expose Codex desktop app updates")

let portableHosts = [
    FleetHost(
        id: "workstation",
        displayName: "This Mac",
        systemImage: "laptopcomputer",
        isLocal: true,
        routes: [SSHRoute(alias: "local", displayName: "Local process")]
    ),
    FleetHost(
        id: "studio",
        displayName: "Studio",
        systemImage: "macmini",
        routes: [SSHRoute(alias: "studio", displayName: "Direct")]
    ),
]
let studioResolvedHosts = FleetHost.resolvingLocalHost(in: portableHosts, hostname: "STUDIO.example.net")
let resolvedStudio = studioResolvedHosts.first(where: { $0.id == "studio" })!
let resolvedWorkstation = studioResolvedHosts.first(where: { $0.id == "workstation" })!
test.require(studioResolvedHosts.filter(\.isLocal).map(\.id) == ["studio"], "the running Mac should become the only local host")
test.require(resolvedStudio.displayName == "This Mac" && resolvedStudio.routes.first?.alias == "local", "the running Mac should use the local process route")
test.require(resolvedWorkstation.displayName == "Workstation" && resolvedWorkstation.routes.first?.alias == "workstation", "the previous local Mac should become a named SSH host")
test.require(FleetHost.resolvingLocalHost(in: portableHosts, hostname: "unknown") == portableHosts, "an unknown hostname should preserve the configured local host")
test.require(
    FleetHost.resolvingLocalHost(in: portableHosts, hostnames: ["customer.example.net", "studio"]).first(where: { $0.id == "studio" })!.isLocal,
    "the localized Mac name should win when DNS reports an unrelated provider hostname"
)

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
let historySummary = HistoryAnalyzer.summary(samples: history)
test.require(historySummary.sampleCount == history.count, "one-pass history summaries should retain the sample count")
test.require(historySummary.availabilityPercent == HistoryAnalyzer.availabilityPercent(samples: history), "summary availability should match the established analyzer")
test.require(historySummary.averageConnectionReadyMilliseconds == HistoryAnalyzer.averageConnectionReadyMilliseconds(samples: history), "summary ready timing should match the established analyzer")
test.require(historySummary.averagePingMilliseconds == HistoryAnalyzer.averagePingMilliseconds(samples: history), "summary ping should match the established analyzer")
test.require(historySummary.averagePingJitterMilliseconds == HistoryAnalyzer.averagePingJitterMilliseconds(samples: history), "summary jitter should match the established analyzer")
test.require(historySummary.averagePacketLossPercent == HistoryAnalyzer.averagePacketLossPercent(samples: history), "summary loss should match the established analyzer")
test.require(historySummary.averageProbeDurationMilliseconds == HistoryAnalyzer.averageProbeDurationMilliseconds(samples: history), "summary probe timing should match the established analyzer")
test.require(historySummary.averageProbeWorkMilliseconds == HistoryAnalyzer.averageProbeWorkMilliseconds(samples: history), "summary work timing should match the established analyzer")
test.require(historySummary.incidentCount == HistoryAnalyzer.incidentCount(samples: history), "summary incidents should match the established analyzer")

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
let sortedWindowHistory = windowHistory.sorted { $0.timestamp < $1.timestamp }
test.require(
    HistoryAnalyzer.recentSortedSamples(sortedWindowHistory, hours: 1, now: windowNow) == oneHourHistory,
    "indexed history windows should match the existing inclusive cutoff behavior"
)
let indexedWindowHistory = HistoryIndexBuilder.build(samples: windowHistory + [
    MetricSample(timestamp: windowNow, hostID: "second", state: .online)
])
test.require(indexedWindowHistory["example"]?.map(\.timestamp) == sortedWindowHistory.map(\.timestamp), "history indexing should repair only an out-of-order host")
test.require(indexedWindowHistory["second"]?.count == 1, "history indexing should group samples by host")
test.require(HistoryAnalyzer.nearestSample(to: windowNow.addingTimeInterval(-10_000), in: sortedWindowHistory) == sortedWindowHistory.first, "nearest history lookup should clamp before the first sample")
test.require(HistoryAnalyzer.nearestSample(to: windowNow.addingTimeInterval(10_000), in: sortedWindowHistory) == sortedWindowHistory.last, "nearest history lookup should clamp after the last sample")
test.require(HistoryAnalyzer.nearestSample(to: sortedWindowHistory[1].timestamp, in: sortedWindowHistory) == sortedWindowHistory[1], "nearest history lookup should return an exact match")
let midpoint = sortedWindowHistory[0].timestamp.addingTimeInterval(sortedWindowHistory[1].timestamp.timeIntervalSince(sortedWindowHistory[0].timestamp) / 2)
test.require(HistoryAnalyzer.nearestSample(to: midpoint, in: sortedWindowHistory) == sortedWindowHistory[0], "equidistant history lookup should prefer the earlier point")
var largeTrendHistory: [MetricSample] = []
largeTrendHistory.reserveCapacity(10_000)
for index in 0..<10_000 {
    let state: HostState = index == 4_321 ? .unreachable : .online
    let ping = index == 7_654 ? 9_999 : 20 + index % 5
    largeTrendHistory.append(MetricSample(
        timestamp: windowNow.addingTimeInterval(Double(index)),
        hostID: "example",
        state: state,
        pingMilliseconds: ping,
        packetLossPercent: index == 6_543 ? 25 : 0,
        diskPercent: 40 + index % 3
    ))
}
let downsampledTrendHistory = TrendSampleDownsampler.downsample(largeTrendHistory, maxPoints: 360)
test.require(downsampledTrendHistory.count <= 360, "large trend charts should respect their rendering budget")
test.require(downsampledTrendHistory.first == largeTrendHistory.first && downsampledTrendHistory.last == largeTrendHistory.last, "trend downsampling should preserve endpoints")
test.require(downsampledTrendHistory.contains(where: { $0.pingMilliseconds == 9_999 }), "trend downsampling should preserve isolated timing spikes")
test.require(downsampledTrendHistory.contains(where: { $0.state == .unreachable }), "trend downsampling should preserve outages")
test.require(downsampledTrendHistory.contains(where: { ($0.packetLossPercent ?? 0) > 0 }), "trend downsampling should preserve packet loss")
test.require(TrendSampleDownsampler.downsample(Array(largeTrendHistory.prefix(50)), maxPoints: 600) == Array(largeTrendHistory.prefix(50)), "small trend sets should remain unchanged")
var sustainedLossHistory: [MetricSample] = []
sustainedLossHistory.reserveCapacity(10_000)
for index in 0..<10_000 {
    let loss: Double = (1_000..<9_000).contains(index) ? 10 : 0
    sustainedLossHistory.append(MetricSample(
        timestamp: windowNow.addingTimeInterval(Double(index)),
        hostID: "example",
        state: .online,
        pingMilliseconds: index == 5_000 ? 12_000 : 25,
        packetLossPercent: loss
    ))
}
let sustainedLossDownsample = TrendSampleDownsampler.downsample(sustainedLossHistory, maxPoints: 600)
test.require(sustainedLossDownsample.contains(where: { $0.pingMilliseconds == 12_000 }), "long incidents should not consume the budget reserved for timing extrema")
test.require(sustainedLossDownsample.contains(where: { $0.timestamp == sustainedLossHistory[1_000].timestamp }), "long packet-loss runs should retain their start boundary")
test.require(sustainedLossDownsample.contains(where: { $0.timestamp == sustainedLossHistory[8_999].timestamp }), "long packet-loss runs should retain their end boundary")
let remoteProbeCommand = RemoteCommandBuilder.build(services: [])
test.require(remoteProbeCommand.contains("RESTART_REQUIRED=required"), "the primary probe should check Linux restart state")
test.require(!remoteProbeCommand.contains("sudo"), "restart-state probes should not require elevated privileges")

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
    supportsLinuxUpdates: true,
    services: [.tailscale, .docker],
    routes: [SSHRoute(alias: "example-server", displayName: "Direct")]
)
let publicConfiguration = FleetConfiguration(hosts: [thisMac, configuredServer])
test.require(publicConfiguration.validationErrors.isEmpty, "a generic public fleet configuration should validate")
test.require(configuredServer.canWake, "a configured MAC address should enable Wake-on-LAN")
test.require(!configuredServer.supportsCodexDesktopApp, "remote hosts should opt in to Codex desktop app updates")
test.require(configuredServer.supportsLinuxUpdates, "configured Linux hosts should opt in to system updates")
let configurationRoundTrip = try decoder.decode(FleetConfiguration.self, from: encoder.encode(publicConfiguration))
test.require(configurationRoundTrip == publicConfiguration, "fleet configuration should round-trip through JSON")
let legacyLinuxHost = try decoder.decode(
    FleetHost.self,
    from: Data(#"{"id":"legacy","displayName":"Legacy","systemImage":"server.rack"}"#.utf8)
)
test.require(!legacyLinuxHost.supportsLinuxUpdates, "older fleet configurations should remain compatible without the Linux update flag")
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
test.require(NetworkDiagnoser.diagnose(snapshot: pingableSSHFailure)?.title == "SSH connection timed out", "SSH timeouts should be classified precisely")
test.require(NetworkDiagnoser.diagnose(snapshot: pingableSSHFailure)?.detail.contains("firewall") == true, "timeout guidance should name likely route and policy causes")
test.require(NetworkDiagnoser.diagnose(snapshot: HostSnapshot(state: .unreachable, pingMilliseconds: 20, detail: "Permission denied (publickey)"))?.title == "SSH authentication rejected", "SSH authentication failures should be classified precisely")
test.require(NetworkDiagnoser.diagnose(snapshot: HostSnapshot(state: .unreachable, pingMilliseconds: 20, detail: "Host key verification failed"))?.title == "SSH host identity blocked", "SSH host-key failures should be classified precisely")
test.require(NetworkDiagnoser.diagnose(snapshot: HostSnapshot(state: .unreachable, pingMilliseconds: 20, detail: "Could not resolve hostname example"))?.title == "SSH name could not be resolved", "SSH DNS failures should be classified precisely")
test.require(NetworkDiagnoser.diagnose(snapshot: HostSnapshot(state: .unreachable, pingMilliseconds: 20, detail: "Connection refused"))?.title == "SSH service refused connection", "refused SSH services should be classified precisely")
test.require(NetworkDiagnoser.diagnose(snapshot: HostSnapshot(state: .unreachable, pingMilliseconds: 20, detail: "Connection closed by UNKNOWN port 65535"))?.title == "SSH connection closed early", "early SSH disconnects should be classified precisely")
test.require(NetworkDiagnoser.diagnose(snapshot: HostSnapshot(state: .unreachable, pingMilliseconds: 20, detail: "Unexpected SSH error"))?.detail.contains("Diagnose in Terminal") == true, "unknown SSH failures should provide an interactive next step")

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
let attentionAccess = FleetHost(id: "attention-access", displayName: "Access", systemImage: "desktopcomputer")
let attentionSlow = FleetHost(id: "attention-slow", displayName: "Slow", systemImage: "desktopcomputer")
let attentionService = FleetHost(id: "attention-service", displayName: "Service", systemImage: "desktopcomputer")
let attentionBoth = FleetHost(id: "attention-both", displayName: "Both", systemImage: "desktopcomputer")
let stoppedDocker = ServiceSnapshot(kind: .docker, state: .stopped, detail: "Stopped")

let serviceHealthyHost = FleetHost(id: "service-healthy", displayName: "Healthy Host", systemImage: "server.rack", services: [.tailscale, .docker])
let serviceOfflineHost = FleetHost(id: "service-offline", displayName: "Offline Host", systemImage: "server.rack", services: [.plex])
let serviceAccessHost = FleetHost(id: "service-access", displayName: "Access Host", systemImage: "server.rack", services: [.samba])
let serviceMissingHost = FleetHost(id: "service-missing", displayName: "Missing Host", systemImage: "server.rack", services: [.tailscale])
let serviceCheckTime = Date(timeIntervalSince1970: 1_720_000_000)
let serviceDashboardSnapshots = [
    serviceHealthyHost.id: HostSnapshot(state: .online, checkedAt: serviceCheckTime, services: [
        ServiceSnapshot(kind: .tailscale, state: .healthy, detail: "Connected"),
        ServiceSnapshot(kind: .docker, state: .stopped, detail: "Stopped"),
    ]),
    serviceOfflineHost.id: HostSnapshot(state: .unreachable, checkedAt: serviceCheckTime),
    serviceAccessHost.id: HostSnapshot(state: .unreachable, checkedAt: serviceCheckTime, pingMilliseconds: 20, packetLossPercent: 0, detail: "Permission denied"),
    serviceMissingHost.id: HostSnapshot(state: .online, checkedAt: serviceCheckTime),
]
let serviceDashboardEntries = FleetServiceAnalyzer.entries(
    hosts: [serviceHealthyHost, serviceOfflineHost, serviceAccessHost, serviceMissingHost],
    snapshots: serviceDashboardSnapshots
)
let serviceDashboardSummary = FleetServiceAnalyzer.summarize(entries: serviceDashboardEntries)
test.require(serviceDashboardEntries.count == 5, "services dashboard should include every configured host service")
test.require(serviceDashboardSummary == FleetServiceSummary(healthyCount: 1, attentionCount: 1, unavailableCount: 3), "services dashboard should separate healthy, attention, and unavailable checks")
test.require(serviceDashboardEntries.first(where: { $0.hostID == serviceOfflineHost.id })?.detail == "Machine offline", "offline machines should not make their services look stopped")
test.require(serviceDashboardEntries.first(where: { $0.hostID == serviceAccessHost.id })?.detail == "Monitoring access issue", "access failures should explain why service state is unavailable")
test.require(serviceDashboardEntries.first(where: { $0.hostID == serviceMissingHost.id })?.detail == "No service result returned", "online hosts with missing checks should be explicit")
test.require(serviceDashboardEntries.first(where: { $0.hostID == serviceHealthyHost.id && $0.kind == .docker })?.state == .stopped, "live service failures should remain actionable")
test.require(serviceDashboardEntries.allSatisfy { $0.checkedAt == serviceCheckTime }, "service rows should retain their machine check time")
test.require(FleetServiceAnalyzer.filtered(entries: serviceDashboardEntries, by: .healthy).count == 1, "healthy service filtering should show only successful checks")
test.require(FleetServiceAnalyzer.filtered(entries: serviceDashboardEntries, by: .attention).map(\.kind) == [.docker], "attention filtering should include stopped and degraded services")
test.require(FleetServiceAnalyzer.filtered(entries: serviceDashboardEntries, by: .unavailable).count == 3, "unavailable filtering should retain unknown service states")
let serviceReport = FleetServiceReportBuilder.build(
    entries: serviceDashboardEntries,
    generatedAt: serviceCheckTime,
    observerName: "Test Observer",
    appVersion: "v1.32 (36)"
)
test.require(serviceReport.contains("Observer: Test Observer · Fleetlight v1.32 (36)"), "service reports should identify their observer and Fleetlight build")
test.require(serviceReport.contains("Configured 5 · Healthy 1 · Attention 1 · Unavailable 3"), "service reports should include unambiguous status totals")
test.require(serviceReport.contains("Docker — 0/1 healthy"), "service reports should group checks by service")
test.require(serviceReport.contains("Healthy Host [service-healthy]: Stopped · Stopped · checked"), "service reports should include machine state, details, and check freshness")
let attentionSnapshots = [
    attentionOffline.id: HostSnapshot(state: .unreachable),
    attentionAccess.id: HostSnapshot(state: .unreachable, pingMilliseconds: 38, packetLossPercent: 0, detail: "Permission denied"),
    attentionSlow.id: HostSnapshot(state: .online, pingMilliseconds: 250),
    attentionService.id: HostSnapshot(state: .online, services: [stoppedDocker]),
    attentionBoth.id: HostSnapshot(state: .online, pingMilliseconds: 300, services: [stoppedDocker]),
]
let attentionSummary = FleetAttentionAnalyzer.summarize(
    hosts: [attentionOffline, attentionAccess, attentionSlow, attentionService, attentionBoth],
    snapshots: attentionSnapshots,
    thresholds: .default
)
test.require(attentionSummary.onlineCount == 3, "attention summary should distinguish connected machines")
test.require(attentionSummary.unreachableCount == 1, "attention summary should reserve offline for machines without a network reply")
test.require(attentionSummary.monitoringAccessIssueCount == 1, "attention summary should separate ping-reachable SSH failures")
test.require(attentionSummary.performanceWarningCount == 2, "attention summary should count slow connected machines")
test.require(attentionSummary.serviceOrResourceAlertCount == 2, "attention summary should separate service and resource alerts")
test.require(attentionSummary.uniqueAttentionCount == 5, "overlapping warning categories should not double-count machines")
test.require(attentionSummary.compactDescription == "1 offline · 1 access issue · 2 slow · 2 alerts", "menu status should retain every simultaneous attention category")
test.require(FleetAttentionSummary(onlineCount: 1, unreachableCount: 0, monitoringAccessIssueCount: 0, performanceWarningCount: 0, serviceOrResourceAlertCount: 0, uniqueAttentionCount: 0).compactDescription == nil, "healthy fleets should not add menu status text")
test.require(FleetAttentionAnalyzer.matches(snapshot: attentionSnapshots[attentionOffline.id]!, thresholds: .default, filter: .offline), "offline filter should include unreachable machines")
test.require(!FleetAttentionAnalyzer.matches(snapshot: attentionSnapshots[attentionAccess.id]!, thresholds: .default, filter: .offline), "offline filter should exclude ping-reachable access failures")
test.require(FleetAttentionAnalyzer.matches(snapshot: attentionSnapshots[attentionAccess.id]!, thresholds: .default, filter: .access), "access filter should include ping-reachable SSH failures")
test.require(FleetConnectionClassifier.status(for: attentionSnapshots[attentionAccess.id]!) == .accessIssue, "connection classification should recognize monitoring access failures")
test.require(FleetConnectionClassifier.status(for: HostSnapshot(state: .unreachable, pingMilliseconds: 38, packetLossPercent: 100)) == .offline, "complete packet loss should remain offline")
test.require(HealthScorer.score(snapshot: attentionSnapshots[attentionAccess.id]!, availability: 100) == 15, "access failures should score above fully offline machines")
test.require(FleetReportBuilder.build(hosts: [attentionAccess], snapshots: attentionSnapshots).contains("Access issue"), "copied diagnostics should describe monitoring access failures accurately")
test.require(FleetReportBuilder.build(hosts: [attentionAccess], snapshots: attentionSnapshots).contains("SSH authentication rejected"), "copied diagnostics should retain the specific SSH failure diagnosis")
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

let mobileFeedCheckedAt = Date(timeIntervalSince1970: 1_720_000_000)
let mobileFeed = MobileFeedDocument(
    generatedAt: mobileFeedCheckedAt,
    observer: MobileFeedObserver(
        id: "observer-one",
        name: "Observer One",
        appVersion: "v1.0 (1)",
        lastRefreshDurationMilliseconds: 640
    ),
    summary: MobileFeedSummary(
        total: 2,
        online: 1,
        offline: 1,
        accessIssues: 0,
        slowConnections: 1,
        alerts: 1,
        updatesAvailable: 1,
        restartRequired: 1
    ),
    hosts: [
        MobileFeedHost(
            id: "example-host",
            name: "Example Host",
            platform: "Linux",
            state: "slow",
            status: "slow",
            detail: "Online with a timing warning",
            checkedAt: mobileFeedCheckedAt,
            issueTypes: ["slow", "alerts"],
            health: 91,
            pingMs: 42,
            jitterMs: 7,
            services: [
                MobileFeedService(kind: "example", name: "Example Service", state: "healthy", detail: "Active")
            ],
            warnings: [
                MobileFeedWarning(kind: "ping", title: "High ping", detail: "Example threshold exceeded")
            ]
        )
    ],
    linuxUpdates: [
        MobileFeedLinuxUpdate(
            hostId: "example-host",
            hostName: "Example Host",
            state: "updateAvailable",
            detail: "1 update available",
            packageManager: "apt",
            availableCount: 1,
            restartRequired: true,
            checkedAt: mobileFeedCheckedAt
        )
    ]
)
let mobileFeedData = try MobileFeedCodec.encode(mobileFeed)
let decodedMobileFeed = try MobileFeedCodec.decode(mobileFeedData)
let mobileFeedJSON = String(decoding: mobileFeedData, as: UTF8.self)
test.require(decodedMobileFeed == mobileFeed && decodedMobileFeed.schemaVersion == 1, "mobile feed schema should round-trip without losing status details")
test.require(decodedMobileFeed.summary.offline == 1 && decodedMobileFeed.summary.slowConnections == 1 && decodedMobileFeed.summary.alerts == 1, "mobile summaries should preserve simultaneous issue categories")
test.require(!mobileFeedJSON.contains("routeAlias") && !mobileFeedJSON.contains("ipAddress") && !mobileFeedJSON.contains("username") && !mobileFeedJSON.contains("command"), "mobile feeds should omit transport routes and fleet credentials")
let redactedMobileDetail = MobileFeedSanitizer.redact("ssh failed for admin@example.net at 192.0.2.34; see /Users/example/.ssh/config and https://private.example/path")
test.require(!redactedMobileDetail.contains("admin@example.net") && !redactedMobileDetail.contains("192.0.2.34") && !redactedMobileDetail.contains("/Users/example") && !redactedMobileDetail.contains("https://"), "mobile feed details should redact addresses, accounts, private paths, and URLs")

let controlGETData = Data("GET /fleetlight/control/v1/status HTTP/1.1\r\nHost: controller\r\nAuthorization: Bearer example\r\n\r\n".utf8)
guard case let .complete(controlGET) = MobileControlHTTPRequestParser.parse(controlGETData) else {
    fatalError("complete mobile control GET should parse")
}
test.require(controlGET.method == "GET" && controlGET.path == "/fleetlight/control/v1/status", "mobile control parser should retain method and exact path")
test.require(controlGET.header("authorization") == "Bearer example", "mobile control parser should normalize header names")

let controlBody = #"{"requestId":"00000000-0000-0000-0000-000000000001","action":"linux-os","targetHostIds":["example-host"]}"#
let controlPOSTText = "POST /control/v1/jobs HTTP/1.1\r\nHost: controller\r\nContent-Type: application/json\r\nContent-Length: \(controlBody.utf8.count)\r\n\r\n\(controlBody)"
let controlPOSTData = Data(controlPOSTText.utf8)
test.require(MobileControlHTTPRequestParser.parse(controlPOSTData.prefix(controlPOSTData.count - 1)) == .incomplete, "mobile control parser should wait for the complete declared JSON body")
guard case let .complete(controlPOST) = MobileControlHTTPRequestParser.parse(controlPOSTData) else {
    fatalError("complete mobile control POST should parse")
}
test.require(String(decoding: controlPOST.body, as: UTF8.self) == controlBody, "mobile control parser should preserve an exact JSON body")

let checkRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
let checkRequest = MobileControlCheckRequest(requestId: checkRequestID)
let checkRequestData = try JSONEncoder().encode(checkRequest)
let checkBody = String(decoding: checkRequestData, as: UTF8.self)
let checkPOSTText = "POST /control/v1/checks HTTP/1.1\r\nHost: controller\r\nContent-Type: application/json\r\nIdempotency-Key: \(checkRequestID.uuidString)\r\nContent-Length: \(checkBody.utf8.count)\r\n\r\n\(checkBody)"
guard case let .complete(checkPOST) = MobileControlHTTPRequestParser.parse(Data(checkPOSTText.utf8)) else {
    fatalError("complete mobile update-check POST should parse")
}
test.require(
    checkPOST.path == "/control/v1/checks"
        && checkPOST.header("idempotency-key") == checkRequestID.uuidString,
    "mobile live checks should preserve the authenticated idempotency key"
)

let duplicateHeaderRequest = Data("GET /control/v1/status HTTP/1.1\r\nHost: one\r\nHost: two\r\n\r\n".utf8)
test.require(MobileControlHTTPRequestParser.parse(duplicateHeaderRequest) == .failure(.malformedRequest), "mobile control parser should reject duplicate headers")
let chunkedRequest = Data("POST /control/v1/jobs HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
test.require(MobileControlHTTPRequestParser.parse(chunkedRequest) == .failure(.unsupportedTransferEncoding), "mobile control parser should reject transfer encodings")
let oversizedBodyRequest = Data("POST /control/v1/jobs HTTP/1.1\r\nContent-Length: 32769\r\n\r\n".utf8)
test.require(MobileControlHTTPRequestParser.parse(oversizedBodyRequest) == .failure(.bodyTooLarge), "mobile control parser should cap JSON bodies at 32 KiB")

let controlJob = MobileControlJob(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
    requestId: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
    action: .codexCLI,
    targetHostIds: ["example-host"],
    state: .running,
    createdAt: mobileFeedCheckedAt,
    startedAt: mobileFeedCheckedAt,
    completed: 0,
    progress: [
        MobileControlHostProgress(hostId: "example-host", phase: "updating", detail: "Updating Codex")
    ]
)
let controlEncoder = JSONEncoder()
controlEncoder.dateEncodingStrategy = .iso8601
let controlDecoder = JSONDecoder()
controlDecoder.dateDecodingStrategy = .iso8601
let controlJobData = try controlEncoder.encode(controlJob)
let decodedControlJob = try controlDecoder.decode(MobileControlJob.self, from: controlJobData)
test.require(decodedControlJob == controlJob, "mobile control job schema should round-trip with request ID and host progress")

let controlCheck = MobileControlCheck(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
    requestId: checkRequestID,
    state: .running,
    phase: "checking-linux-packages",
    detail: "Checking Linux package sources",
    startedAt: mobileFeedCheckedAt
)
let controlCheckData = try controlEncoder.encode(controlCheck)
let controlCheckJSON = String(decoding: controlCheckData, as: UTF8.self)
let decodedControlCheck = try controlDecoder.decode(MobileControlCheck.self, from: controlCheckData)
test.require(
    decodedControlCheck == controlCheck
        && decodedControlCheck.schemaVersion == 1
        && decodedControlCheck.completed == 0
        && decodedControlCheck.total == 3
        && decodedControlCheck.progress?.map(\.id) == ["fleet", "linux", "publishing"]
        && controlCheckJSON.contains(#""requestId""#)
        && controlCheckJSON.contains(#""startedAt""#)
        && controlCheckJSON.contains(#""finishedAt""#) == false,
    "mobile live checks should round-trip their stable asynchronous wire fields"
)
let progressItemData = try JSONEncoder().encode(MobileControlCheckProgressPlan.initial()[0])
let progressItemObject = try JSONSerialization.jsonObject(with: progressItemData) as? [String: Any]
test.require(
    Set(progressItemObject?.keys.map { $0 } ?? []) == Set(["id", "name", "category", "state", "detail"]),
    "mobile check progress items should expose exactly the five additive wire fields"
)
test.require(
    MobileControlCheckProgressPlan.stepIDs == ["fleet", "linux", "publishing"]
        && MobileControlCheckProgressPlan.initial().map(\.id) == MobileControlCheckProgressPlan.stepIDs
        && MobileControlCheckProgressPlan.initial().map(\.name) == ["Installed versions", "Linux packages", "Publish results"]
        && MobileControlCheckProgressPlan.initial().map(\.category) == ["fleet", "linux", "publishing"]
        && MobileControlCheckProgressPlan.initial().allSatisfy { $0.state == "queued" },
    "mobile checks should use three stable ordered progress stages"
)
let unsafeProgress = [
    MobileControlCheckProgressItem(
        id: "fleet",
        name: "Private machine",
        category: "secret",
        state: "unknown",
        detail: "Contact admin@example.net at https://private.invalid/\nnow"
    ),
    MobileControlCheckProgressItem(id: "extra", name: "Extra", category: "extra", state: "running", detail: "Extra"),
]
let normalizedProgress = MobileControlCheckProgressPlan.normalized(unsafeProgress)
test.require(
    normalizedProgress.count == 3
        && normalizedProgress[0].name == "Installed versions"
        && normalizedProgress[0].category == "fleet"
        && normalizedProgress[0].state == "queued"
        && !normalizedProgress[0].detail.contains("admin@example.net")
        && !normalizedProgress[0].detail.contains("https://")
        && !normalizedProgress[0].detail.contains("\n")
        && !normalizedProgress.contains(where: { $0.id == "extra" }),
    "mobile check progress should be canonical, bounded, and privacy-sanitized"
)
let completedFleetProgress = MobileControlCheckProgressPlan.updating(
    MobileControlCheckProgressPlan.initial(),
    id: "fleet",
    state: .succeeded,
    detail: "Installed versions checked"
)
let failedIncompleteProgress = MobileControlCheckProgressPlan.failingIncomplete(
    completedFleetProgress,
    detail: "Controller stopped at admin@example.net\nbefore completion"
)
test.require(
    failedIncompleteProgress.map(\.state) == ["succeeded", "failed", "failed"]
        && MobileControlCheckProgressPlan.completedCount(failedIncompleteProgress) == 3
        && failedIncompleteProgress[1].detail == "Controller stopped at [account] before completion",
    "terminal recovery should preserve completed work and fail every unfinished canonical stage"
)
let legacyControlCheckData = Data(#"{"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000022","requestId":"00000000-0000-0000-0000-000000000002","state":"succeeded","phase":"complete","detail":"Checked"}"#.utf8)
let legacyControlCheck = try controlDecoder.decode(MobileControlCheck.self, from: legacyControlCheckData)
test.require(
    legacyControlCheck.completed == nil && legacyControlCheck.total == nil && legacyControlCheck.progress == nil,
    "mobile check journals written before additive progress fields should still decode"
)
let futureControlCheckData = Data(#"{"schemaVersion":2,"id":"00000000-0000-0000-0000-000000000022","requestId":"00000000-0000-0000-0000-000000000002","state":"succeeded","phase":"complete","detail":"Checked"}"#.utf8)
test.require(
    (try? controlDecoder.decode(MobileControlCheck.self, from: futureControlCheckData)) == nil,
    "mobile checks should reject unsupported record schemas instead of changing their wire meaning"
)
let oversizedControlCheckData = Data(#"{"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000023","requestId":"00000000-0000-0000-0000-000000000002","state":"running","phase":"fleet","detail":"Checking","completed":99,"total":99,"progress":[{"id":"fleet","name":"Wrong","category":"wrong","state":"running","detail":"Checking"},{"id":"extra","name":"Extra","category":"extra","state":"running","detail":"Extra"}]}"#.utf8)
let boundedControlCheck = try controlDecoder.decode(MobileControlCheck.self, from: oversizedControlCheckData)
test.require(
    boundedControlCheck.completed == 3
        && boundedControlCheck.total == 3
        && boundedControlCheck.progress?.count == 3
        && boundedControlCheck.progress?.map(\.id) == ["fleet", "linux", "publishing"],
    "decoded mobile check progress should be bounded to the canonical three stages"
)
let canonicalTotalCheck = MobileControlCheck(
    requestId: checkRequestID,
    completed: 99,
    total: 1,
    progress: unsafeProgress
)
test.require(
    canonicalTotalCheck.completed == 3
        && canonicalTotalCheck.total == 3
        && canonicalTotalCheck.progress?.first?.state == "queued",
    "any present mobile check total should canonicalize to the shared three-stage contract"
)
test.require(
    MobileControlCheckOutcome.state(successfulComponents: 4, failedComponents: 0) == .succeeded
        && MobileControlCheckOutcome.state(successfulComponents: 3, failedComponents: 1) == .partial
        && MobileControlCheckOutcome.state(successfulComponents: 0, failedComponents: 2) == .failed
        && MobileControlCheckOutcome.state(successfulComponents: 0, failedComponents: 0) == .failed,
    "mobile live checks should distinguish complete, partial, and failed source results"
)
let publishedFailure = MobileControlCheckCompletionPlanner.plan(
    successfulSources: 0,
    failedSources: 4,
    feedPublished: true
)
let unpublishedPartial = MobileControlCheckCompletionPlanner.plan(
    successfulSources: 4,
    failedSources: 0,
    feedPublished: false
)
let publishedPartial = MobileControlCheckCompletionPlanner.plan(
    successfulSources: 3,
    failedSources: 1,
    feedPublished: true
)
test.require(
    publishedFailure.state == .failed
        && publishedFailure.detail.contains("Failure results published")
        && unpublishedPartial.state == .partial
        && unpublishedPartial.detail.contains("could not be published")
        && !unpublishedPartial.detail.contains("Fresh results published")
        && publishedPartial.state == .partial
        && publishedPartial.detail.contains("Fresh results published"),
    "mobile check completion should keep source success separate from truthful feed publication"
)
let refreshOwnerID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
test.require(
    MobileControlRefreshOwnership.permits(activeCheckId: nil, requestedCheckId: nil)
        && MobileControlRefreshOwnership.permits(activeCheckId: refreshOwnerID, requestedCheckId: refreshOwnerID)
        && !MobileControlRefreshOwnership.permits(activeCheckId: refreshOwnerID, requestedCheckId: nil)
        && !MobileControlRefreshOwnership.permits(activeCheckId: nil, requestedCheckId: refreshOwnerID),
    "fleet refreshes should run only without an active check or for the owning live check"
)
let releaseURL = URL(string: "https://example.invalid/latest")!
let freshReleaseRequest = MobileControlReleaseRequestPolicy.request(
    url: releaseURL,
    accept: "application/json",
    bypassCaches: true
)
let routineReleaseRequest = MobileControlReleaseRequestPolicy.request(
    url: releaseURL,
    accept: "application/json",
    bypassCaches: false
)
test.require(
    freshReleaseRequest.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData
        && freshReleaseRequest.value(forHTTPHeaderField: "Cache-Control") == "no-cache"
        && freshReleaseRequest.value(forHTTPHeaderField: "Pragma") == "no-cache"
        && freshReleaseRequest.value(forHTTPHeaderField: "Accept") == "application/json"
        && routineReleaseRequest.cachePolicy == .useProtocolCachePolicy
        && routineReleaseRequest.value(forHTTPHeaderField: "Cache-Control") == nil,
    "explicit release checks should bypass URL caches while routine polling retains protocol caching"
)
let completedChecks = (0..<102).map { index in
    MobileControlCheck(
        requestId: UUID(),
        state: .succeeded,
        phase: "complete",
        detail: "Checked",
        startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
        finishedAt: Date(timeIntervalSince1970: TimeInterval(index))
    )
}
let activeCheck = MobileControlCheck(requestId: UUID(), state: .running, phase: "publishing")
let retainedChecks = MobileControlCheckRetention.retained(completedChecks + [activeCheck])
test.require(
    retainedChecks.count == 101
        && retainedChecks.contains(where: { $0.id == activeCheck.id })
        && retainedChecks.contains(where: { $0.id == completedChecks.last?.id })
        && !retainedChecks.contains(where: { $0.id == completedChecks.first?.id }),
    "mobile check journals should retain every active check and only the latest 100 read-only results"
)

let restartJobRequest = MobileControlJobRequest(
    requestId: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
    action: .restartLinux,
    targetHostIds: ["example-host"]
)
let restartJobRequestData = try controlEncoder.encode(restartJobRequest)
let restartJobRequestJSON = String(decoding: restartJobRequestData, as: UTF8.self)
let decodedRestartJobRequest = try controlDecoder.decode(MobileControlJobRequest.self, from: restartJobRequestData)
test.require(
    restartJobRequestJSON.contains(#""action":"restart-linux""#)
        && decodedRestartJobRequest == restartJobRequest,
    "mobile control should round-trip the typed restart-linux wire action"
)
test.require(
    MobileControlAction.allCases.map(\.rawValue) == ["codex-cli", "codex-mac-app", "linux-os", "restart-linux"],
    "mobile control should publish all four stable action identifiers"
)
test.require(
    MobileControlActionPolicy.acceptsTargetCount(action: .restartLinux, count: 1)
        && !MobileControlActionPolicy.acceptsTargetCount(action: .restartLinux, count: 0)
        && !MobileControlActionPolicy.acceptsTargetCount(action: .restartLinux, count: 2),
    "mobile Linux restarts should require exactly one target and reject restart-all"
)
test.require(
    MobileControlActionPolicy.acceptsTargetCount(action: .codexCLI, count: 2)
        && MobileControlActionPolicy.acceptsTargetCount(action: .codexMacApp, count: 1)
        && MobileControlActionPolicy.acceptsTargetCount(action: .linuxOS, count: 3),
    "existing update actions should continue accepting one or more targets"
)

func restartEligibility(
    online: Bool = true,
    linux: Bool = true,
    required: Bool = true
) -> Bool {
    MobileControlActionPolicy.isEligible(
        action: .restartLinux,
        hostIsOnline: online,
        supportsCodexDesktopApp: false,
        supportsLinuxUpdates: linux,
        codexCliUpdateAvailable: false,
        codexMacAppUpdateAvailable: false,
        linuxUpdateAvailable: false,
        restartRequired: required
    )
}
test.require(
    restartEligibility()
        && !restartEligibility(online: false)
        && !restartEligibility(linux: false)
        && !restartEligibility(required: false),
    "restart eligibility should require an online Linux host with a live restart requirement"
)
test.require(
    MobileControlActionPolicy.isSupported(
        action: .restartLinux,
        hostIsOnline: true,
        supportsCodexDesktopApp: false,
        supportsLinuxUpdates: true
    )
        && MobileControlActionPolicy.isSupported(
            action: .restartLinux,
            hostIsOnline: false,
            supportsCodexDesktopApp: false,
            supportsLinuxUpdates: true
        )
        && !MobileControlActionPolicy.isSupported(
            action: .restartLinux,
            hostIsOnline: true,
            supportsCodexDesktopApp: false,
            supportsLinuxUpdates: false
        ),
    "restart-linux support should follow Linux maintenance capability rather than transient online state"
)
test.require(
    MobileControlActionPolicy.isSupported(
        action: .codexCLI,
        hostIsOnline: true,
        supportsCodexDesktopApp: false,
        supportsLinuxUpdates: false
    )
        && MobileControlActionPolicy.isSupported(
            action: .linuxOS,
            hostIsOnline: true,
            supportsCodexDesktopApp: false,
            supportsLinuxUpdates: true
        ),
    "supported actions should remain visible even when no update is currently available"
)
test.require(
    MobileControlActionPolicy.isEligible(
        action: .codexCLI,
        hostIsOnline: true,
        supportsCodexDesktopApp: false,
        supportsLinuxUpdates: true,
        codexCliUpdateAvailable: true,
        codexMacAppUpdateAvailable: false,
        linuxUpdateAvailable: false,
        restartRequired: false
    )
        && !MobileControlActionPolicy.isEligible(
            action: .linuxOS,
            hostIsOnline: true,
            supportsCodexDesktopApp: false,
            supportsLinuxUpdates: true,
            codexCliUpdateAvailable: false,
            codexMacAppUpdateAvailable: false,
            linuxUpdateAvailable: false,
            restartRequired: true
        ),
    "existing update jobs should remain gated by their per-host availability state"
)

let restartCapability = MobileControlHostCapability(
    hostId: "example-host",
    hostName: "Example Host",
    state: "online",
    actions: [.codexCLI, .linuxOS, .restartLinux],
    codexCliUpdateAvailable: false,
    codexMacAppUpdateAvailable: false,
    linuxUpdateAvailable: false,
    restartRequired: true,
    linuxCheckedAt: mobileFeedCheckedAt
)
let restartCapabilityData = try controlEncoder.encode(restartCapability)
let decodedRestartCapability = try controlDecoder.decode(MobileControlHostCapability.self, from: restartCapabilityData)
test.require(
    decodedRestartCapability == restartCapability
        && decodedRestartCapability.restartRequired
        && decodedRestartCapability.linuxCheckedAt == mobileFeedCheckedAt
        && decodedRestartCapability.actions.contains(.restartLinux),
    "mobile capabilities should expose supported actions and restart-required state independently"
)

let controlStatus = MobileControlStatus(
    generatedAt: mobileFeedCheckedAt,
    controllerId: "example-controller",
    controllerName: "Example Controller",
    appVersion: "v1.0 (1)",
    commandAuthorityEnabled: true,
    jobJournalAvailable: true,
    pairedDeviceCount: 1,
    busy: true,
    activeJobId: nil,
    checkingUpdates: true,
    activeCheckId: controlCheck.id,
    latestCodexCliVersion: "0.145.0",
    codexCliCheckedAt: mobileFeedCheckedAt,
    codexCliCheckFailed: false,
    latestCodexMacAppVersion: "26.708.10000",
    latestCodexMacAppBuild: "5220",
    codexMacAppCheckedAt: mobileFeedCheckedAt,
    codexMacAppCheckFailed: false,
    capabilities: [restartCapability],
    recentJobs: []
)
let controlStatusJSON = String(decoding: try controlEncoder.encode(controlStatus), as: UTF8.self)
test.require(
    controlStatusJSON.contains(#""checkingUpdates":true"#)
        && controlStatusJSON.contains(#""activeCheckId""#)
        && controlStatusJSON.contains(#""latestCodexCliVersion":"0.145.0""#)
        && controlStatusJSON.contains(#""codexCliCheckedAt""#)
        && controlStatusJSON.contains(#""latestCodexMacAppVersion":"26.708.10000""#)
        && controlStatusJSON.contains(#""codexMacAppCheckedAt""#)
        && controlStatusJSON.contains(#""linuxCheckedAt""#),
    "mobile status should expose live-check activity, latest releases, and per-Linux-host freshness"
)

let liveRestartProgress = MobileControlProgressMapper.map(
    hostId: "example-host",
    phase: "waitingForOnline",
    detail: "Waiting for admin@example.net at 192.0.2.10"
)
test.require(
    liveRestartProgress.phase == "waitingForOnline"
        && liveRestartProgress.detail == "Waiting for [account] at [address]"
        && !MobileControlProgressMapper.isTerminal(liveRestartProgress),
    "restart progress mapping should preserve intermediate phases and redact transport details"
)
let finishedRestartProgress = MobileControlProgressMapper.map(
    hostId: "example-host",
    phase: "succeeded",
    detail: "Restart verified"
)
test.require(
    MobileControlProgressMapper.isTerminal(finishedRestartProgress)
        && MobileControlProgressMapper.map(hostId: "example-host", phase: nil, detail: nil).phase == "queued",
    "restart progress mapping should distinguish terminal results and provide a safe queued fallback"
)

test.require(
    MobileControlLinuxRestartPreflight.decision(for: .required) == .proceed
        && MobileControlLinuxRestartPreflight.decision(for: .notRequired) == .skipNoLongerRequired
        && MobileControlLinuxRestartPreflight.decision(for: .offline) == .failOffline
        && MobileControlLinuxRestartPreflight.decision(for: .unsupported) == .failVerification
        && MobileControlLinuxRestartPreflight.decision(for: .failed) == .failVerification,
    "mobile restart preflight should proceed only after an unambiguous live required result"
)
test.require(
    MobileControlLinuxRestartPreflight.postflightIsVerified(.current)
        && MobileControlLinuxRestartPreflight.postflightIsVerified(.updateAvailable)
        && !MobileControlLinuxRestartPreflight.postflightIsVerified(.failed)
        && !MobileControlLinuxRestartPreflight.postflightIsVerified(.offline),
    "mobile restart jobs should report success only after a conclusive post-reboot Linux status check"
)
test.require(
    MobileControlInterruption.detail(for: .restartLinux).contains("outcome unknown")
        && !MobileControlInterruption.detail(for: .codexCLI).contains("outcome unknown"),
    "interrupted restart jobs should preserve an explicit indeterminate result without replaying the reboot"
)
let controlErrorData = try controlEncoder.encode(MobileControlAPIErrorBody(code: "controller-busy", message: "Another operation is running"))
let decodedControlError = try controlDecoder.decode(MobileControlAPIErrorBody.self, from: controlErrorData)
test.require(decodedControlError.error.code == "controller-busy" && decodedControlError.error.message == "Another operation is running", "mobile control errors should use the documented nested error schema")


print("Fleetlight self-test: \(test.count) checks passed")
