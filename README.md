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
- Unified Codex Update Center with concurrent release checks, a combined CLI/Mac app update count, and one confirmed action that runs outdated CLI machines first and Mac app updates second
- Linux System Update Center with distro and kernel versions, pending system/Snap/Flatpak counts, and installed-to-available package versions
- Confirmed per-machine updates or restart-safe sequential fleet updates through apt, dnf, yum, pacman, zypper, or apk, followed by availability verification
- Explicit restart-required results without automatic reboots; Linux checks, updates, and user-confirmed restarts require non-interactive passwordless sudo on remote hosts
- Confirmed per-machine and sequential Restart Required actions that wait for shutdown, verify SSH recovery or a changed boot time, and recheck the Linux restart flag
- Bidirectional live restart verification during every normal fleet refresh, so multiple Fleetlight observers detect new restart requirements, clear stale badges and completed-operation wording, and show when each restart status was verified
- A lightweight **Verify Now** action and restart freshness summary that separates recently verified, stale, unverified, and restart-required Linux machines without refreshing package metadata
- Privacy-safe observer snapshots and a visible agreement check, so two Macs running Fleetlight expose stale or contradictory restart summaries instead of silently showing different answers
- Expandable per-observer diagnostics with Fleetlight version, report age, restart count, verification coverage, and an on-demand **Recheck** action
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

## Privacy

Fleetlight has no analytics, telemetry, account system, or hosted backend. Configuration and monitoring history remain under `~/Library/Application Support/Fleetlight/`. To check update availability, Fleetlight makes cached HTTPS requests to npm's public `@openai/codex` metadata and OpenAI’s public Codex Mac appcast at most once every 15 minutes; it sends no fleet configuration or machine measurements. Exported diagnostics can contain your machine labels and network measurements, so review them before sharing.

The first desktop app update may ask for permission to control System Events. Approve Fleetlight under **System Settings → Privacy & Security → Automation** (and Accessibility if macOS requests it). Fleetlight uses that access only to choose ChatGPT/Codex’s **Check for Updates…** command and its signed install/relaunch action.

## License

MIT. See [`LICENSE`](LICENSE).
