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
- `services`: optional checks for `tailscale`, `docker`, `plex`, or `samba`
- `routes`: one or more SSH aliases tried in order
- `wakeMACAddress`: optional MAC address enabling Wake-on-LAN
- `wakeBroadcastAddress`: optional IPv4 broadcast address; defaults to `255.255.255.255`

## Features

- Concurrent local and SSH health checks with verification markers and hard timeouts
- Online, Offline, Slow, Alerts, and All Issues drill-down filters
- One combined menu-bar label that preserves simultaneous states, such as `1 offline · 2 slow · 1 alert`
- Persistent pinned machines plus Issues First, Lowest Health, Ping, and Name sorting
- Ping, jitter, packet loss, SSH-ready time, full-probe time, disk, memory, load, and uptime
- Current Codex CLI version for every online machine, choosing the newest user-level or NVM installation when duplicates exist
- Cached checks of npm's stable Codex release, with per-machine update badges and a fleet-level available-version summary
- Confirmed one-click Codex updates across the fleet, with restart-safe resume, sequential progress, version verification, and individual update actions
- Clear Codex update outcomes for not-yet-attempted, offline, failed, and verified machines, including shell-wrapper-aware updates
- Configurable performance-warning thresholds
- Seven-day local metric history with 1-hour, 6-hour, 24-hour, and 7-day charts
- Live fleet timing comparison and plain-language network diagnosis
- Thirty-day incident history with restart-safe active issue reconstruction
- Optional notifications for confirmed outages, recoveries, and service transitions
- Multiple SSH recovery routes per machine
- Generic Wake-on-LAN followed by verified SSH recovery checks
- CSV history export and copyable fleet diagnostics
- Optional launch at login

## Privacy

Fleetlight has no analytics, telemetry, account system, or hosted backend. Configuration and monitoring history remain under `~/Library/Application Support/Fleetlight/`. To check update availability, Fleetlight makes a cached HTTPS request to npm's public `@openai/codex` metadata at most once every 15 minutes; it sends no fleet configuration or machine measurements. Exported diagnostics can contain your machine labels and network measurements, so review them before sharing.

## License

MIT. See [`LICENSE`](LICENSE).
