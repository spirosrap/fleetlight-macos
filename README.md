# Fleetlight

Fleetlight is a native macOS menu-bar dashboard for monitoring Macs and Linux machines over SSH. It keeps its configuration, metrics, and incident history on your Mac and does not require a server or cloud account.

The public edition starts with one safe entry—This Mac. It contains no bundled hostnames, IP addresses, SSH usernames, private keys, service endpoints, recovery routes, or telemetry.

## Requirements

- macOS 14 or newer
- Swift 6 / Xcode command-line tools
- Key-based SSH aliases in `~/.ssh/config` for remote machines

Fleetlight runs SSH non-interactively with strict timeouts. It never stores SSH passwords or private keys.

## Build and run

```sh
swift run Fleetlight
```

Run the self-test suite:

```sh
swift run FleetlightSelfTest
```

Build a signed `.app` bundle. Without `APP_IDENTITY`, the script uses ad-hoc signing:

```sh
./Scripts/build_app.sh
```

To use a Developer ID or local development certificate:

```sh
APP_IDENTITY="Your Signing Identity" ./Scripts/build_app.sh
```

Install or replace the app with a clean menu-scene handoff, then verify that its panel is genuinely rendered on screen:

```sh
./Scripts/install_and_launch.sh
./Scripts/verify_menu_panel.sh
```

The optional panel smoke test uses System Events and therefore needs Accessibility permission for the terminal running it; Fleetlight itself does not.

## Configure your fleet

On first launch Fleetlight creates:

```text
~/Library/Application Support/Fleetlight/fleet.json
```

Open Settings → Fleet configuration → Open `fleet.json`, edit it, then choose Reload Configuration. A documented generic template is included as [`fleet.example.json`](fleet.example.json).

When a configured machine ID matches the current Mac's localized computer name or hostname, Fleetlight automatically treats that entry as This Mac and moves the previously local entry back to its SSH route. This DNS-resistant check lets one fleet configuration travel between Macs without making either machine SSH into itself.

Remote routes are SSH aliases, not addresses or credentials. For example:

```sshconfig
Host home-server
  HostName server.example.net
  User operator
  IdentityFile ~/.ssh/id_ed25519
```

Supported machine fields:

- `id`: stable unique identifier
- `displayName`: label shown in Fleetlight
- `systemImage`: optional SF Symbol name
- `isLocal`: use a local process instead of SSH; at most one entry may be local
- `codexDesktopApp`: set to `true` on a macOS host to show its signed Codex/ChatGPT app version and enable app updates
- `linuxUpdates`: set to `true` on Linux hosts to keep them visible in the Linux Update Center even while offline
- `services`: optional checks for `tailscale`, `docker`, `plex`, or `samba`
- `routes`: one or more SSH aliases tried in order
- `wakeMACAddress`: optional MAC address enabling Wake-on-LAN
- `wakeBroadcastAddress`: optional IPv4 broadcast address; defaults to `255.255.255.255`

## Features

- Always-visible Fleetlight version and build badge sourced directly from the running app bundle
- Observer provenance in the header, Settings, and copied diagnostics, including the monitoring Mac and last completed refresh time
- Concurrent local and SSH health checks with verification markers and hard timeouts
- Manual refreshes requested during Linux checks, updates, verification, or restarts are visibly queued, coalesced, and run automatically after the complete maintenance workflow finishes
- Progressive per-machine results with preserved card data, parallel SSH, ping, and service work, cancellable fallback routes, secure short-lived SSH connection reuse, non-blocking background cold validation, instrumented first-result timing, and visible end-to-end timing
- Online, Offline, Access, Slow, Alerts, and All Issues drill-down filters; a ping-reachable machine with failed SSH monitoring is an Access issue instead of being mislabeled offline
- One combined menu-bar label that preserves simultaneous states, such as `1 offline · 1 access issue · 2 slow · 1 alert`
- Persistent pinned machines plus Issues First, Lowest Health, Ping, and Name sorting
- Fleet-wide Services dashboard grouped by check type, with Healthy, Attention, and Unavailable totals plus clear per-machine reasons
- Clickable service-status filters, per-machine check times, manual refresh, and a copyable fleet service report with observer and app-version provenance
- Ping, jitter, packet loss, SSH-ready time, full-probe time, disk, memory, load, and uptime
- Current Codex CLI version for every online machine, choosing the newest user-level or NVM installation when duplicates exist
- Optional Codex desktop app version and build reporting for configured macOS hosts
- Separate Mac App and CLI views in the Codex dashboard, opening on the Mac App view so signed app versions and builds are immediately visible
- Mac App summaries for current, update available, offline, missing, and unknown states, with explicit per-machine last-check times and a copyable version report
- Cached checks of OpenAI’s official Codex Mac app feed, with latest version/build details, per-Mac Current or Update Available status, and targeted updates for outdated Macs only
- Optional one-time macOS alerts when a new Codex CLI or Mac app release affects an online machine, with visible feed-check freshness and per-release deduplication
- Unified Codex Update Center with an explicitly read-only **Check All** action that refreshes installed versions, both release sources, Linux package metadata, and the mobile feed with visible three-stage progress and a timestamped result; its separate confirmed update action still runs outdated CLI machines first and Mac app updates second
- Linux System Update Center with distro and kernel versions, pending system/Snap/Flatpak counts, and installed-to-available package versions
- Package-health checks that detect incomplete `dpkg` configuration even when no upgrades remain, plus actionable DKMS, package, lock, and disk failure details
- Confirmed per-machine updates or restart-safe sequential fleet updates through apt, dnf, yum, pacman, zypper, or apk, followed by availability verification
- Automatic revalidation of saved Linux update failures after a machine is repaired, clearing obsolete red results only after a fresh package check verifies the system is current
- Explicit restart-required results without automatic reboots; Linux checks, updates, and user-confirmed restarts require non-interactive passwordless sudo on remote hosts
- Confirmed per-machine and sequential Restart Required actions that wait for shutdown, verify SSH recovery or a changed boot time, and recheck the Linux restart flag
- Bidirectional live restart verification during every normal fleet refresh, so multiple Fleetlight observers detect new restart requirements, clear stale badges and completed-operation wording, and show when each restart status was verified
- A lightweight **Verify Now** action and restart freshness summary that separates recently verified, stale, unverified, and restart-required Linux machines without refreshing package metadata
- Privacy-safe observer snapshots, one-minute heartbeats, and a visible agreement check, so two Macs running Fleetlight expose genuinely stale or contradictory restart summaries instead of silently showing different answers
- An atomic, versioned mobile feed for the Fleetlight Android companion, designed for tailnet-only delivery without placing fleet SSH keys or sudo credentials on the phone
- Per-Mac Fleetlight versions and pinned-machine priority in the mobile feed, so Android mirrors the observer identity and ordering chosen on macOS
- Optional Android maintenance control through one designated Mac observer, with short-lived pairing, per-device credentials, explicit target confirmation, idempotent jobs, sequential Codex CLI/Codex Mac app/Linux OS execution, confirmed individual Linux restarts, and live per-machine results
- Authenticated read-only Android rechecks for one machine or the visible fleet, with fresh Online or Offline results and one atomic feed publication without package or release audits
- Shared local and authenticated Android read-only update checks that asynchronously force fresh installed-version probes, npm and official Mac app release lookups, Linux package checks with one retry for transient connection failures, and mobile-feed publication without installing, updating, or restarting anything
- Neutral live maintenance reporting during long Linux operations, with prompt recovery checks when work finishes instead of a persistent stale-observer warning
- Expandable per-observer diagnostics with Fleetlight version, report age, restart count, verification coverage, and an on-demand **Fetch Reports** action
- Automatic lightweight package revalidation after a previously offline Linux machine is reachable again, replacing stale red warnings with current package status while respecting a retry cooldown
- Confirmed per-Mac and fleet-wide desktop app updates through OpenAI’s signed updater, with automatic relaunch and post-update verification
- Dedicated Codex dashboard with fleet-wide Current, Updates, Offline, and Unknown counts plus per-machine versions and direct update actions
- Cached checks of npm's stable Codex release, with per-machine update badges and a fleet-level available-version summary
- Smart Codex updates that target only outdated online machines by default, with a manual latest-version check and an explicit Update All override
- Persistent Codex update results with separate verified, offline, and failed totals plus reachable-only retries that keep unresolved machines listed
- Automatic reconciliation of saved Codex update failures after a fresh online probe and successful release check verify that the installed CLI is current
- Time-stamped previous Codex operation results, explicit historical row labels, and a Clear Result action that never changes live version status
- Confirmed one-click Codex updates across the fleet, with restart-safe resume, sequential progress, version verification, and individual update actions
- Clear Codex update outcomes for not-yet-attempted, offline, failed, and verified machines, including shell-wrapper-aware updates
- Configurable performance-warning thresholds
- Runtime host detection for portable fleet configurations, with direct local monitoring and no SSH loopback on whichever configured Mac is running Fleetlight
- Seven-day local metric history with 1-hour, 6-hour, 24-hour, and 7-day charts
- Launch-time history hydration runs alongside live probes, with an off-main-thread per-host index and no redundant global sample copy
- Indexed windows, one-pass cached statistics, binary cursor lookup, lazy chart construction, and event-aware 360-point rendering keep seven-day Trends smooth without hiding outages, packet loss, or timing spikes
- Live fleet timing comparison and plain-language network diagnosis
- Actionable SSH diagnosis for authentication, host-key, DNS, refused, timeout, route, and early-close errors, plus interactive Terminal troubleshooting from Access-state cards
- Thirty-day incident history with restart-safe active issue reconstruction
- Optional notifications for confirmed outages, recoveries, and service transitions
- Multiple SSH recovery routes per machine
- Generic Wake-on-LAN followed by verified SSH recovery checks
- CSV history export and copyable fleet diagnostics
- Optional launch at login

## Android companion feed

After each reconciled refresh, Fleetlight atomically writes a read-only mobile snapshot to `~/Library/Application Support/Fleetlight/mobile/mobile-feed.json`. A loopback-only server exposes that file at `http://127.0.0.1:8787/mobile-feed.json`; it contains display-ready fleet health but no SSH keys, credentials, commands, usernames, or IP addresses.

To expose that directory only to devices already authorized on the same Tailscale network:

```sh
./Scripts/configure_mobile_feed.sh
```

The script health-checks the local feed, preserves existing Tailscale Serve routes, proxies it under `/fleetlight`, and prints the HTTPS endpoint to enter in the Android app. Configure both Mac observers in Android for automatic freshest-report failover.

Android update control is disabled by default. In Fleetlight Settings, enable **Android control** on exactly one always-on observer, create an eight-digit pairing code, and pair that observer from the Android app while both devices are on the same tailnet. The paired phone can request a lightweight read-only health recheck for one or more machines, the same fresh read-only **Check All** pipeline available in the Mac app, Fleetlight's predefined Codex CLI, Codex Mac app, and Linux OS update workflows, or a confirmed restart for one Linux machine that currently requires it; it cannot send commands, SSH routes, package names, or credentials. A health recheck runs the same live probes as the Mac interface and publishes one new mobile snapshot; an Offline result is a successful fresh observation, not a failed control job. Check All additionally reports bounded progress for installed versions, Linux packages, and publication; it refreshes the npm Codex CLI release and OpenAI's Codex Mac appcast, retries a transient failed Linux source once, and then publishes a new mobile feed. Checks are asynchronous and idempotent, cannot overlap maintenance, and never install, update, or restart anything. Every maintenance request shows the exact target machines for confirmation, is deduplicated by request ID, and continues sequentially on the Mac if the phone disconnects. Before an Android-requested restart, Fleetlight rechecks the live Linux reboot flag and never reboots if that check is cleared or inconclusive. Linux updates never reboot a machine automatically.

## Privacy

Fleetlight has no analytics, telemetry, account system, or hosted backend. Configuration and monitoring history remain under `~/Library/Application Support/Fleetlight/`. Routine refreshes cache HTTPS requests to npm's public `@openai/codex` metadata and OpenAI’s public Codex Mac appcast for up to 15 minutes; a local or authenticated Android **Check All** intentionally refreshes both public sources immediately, checks configured machines, and republishes the local mobile feed. It never installs or restarts anything. Fleetlight sends no fleet configuration or machine measurements to either public release source. Exported diagnostics can contain your machine labels and network measurements, so review them before sharing.

Codex desktop app updates use OpenAI's official appcast and download. Fleetlight verifies the bundle identifier, version, OpenAI Developer ID team, and complete code signature before installation, keeps the previous app until the replacement verifies successfully, and then relaunches Codex. No Automation or Accessibility permission is required.

## License

MIT. See [`LICENSE`](LICENSE).
