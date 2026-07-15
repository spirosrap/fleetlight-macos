import Foundation
import FleetlightCore

enum HostLinuxUpdatePhase: String, Codable, Equatable {
    case notAttempted
    case updating
    case succeeded
    case offline
    case failed

    var isTerminal: Bool {
        switch self {
        case .succeeded, .offline, .failed: true
        case .notAttempted, .updating: false
        }
    }
}

struct HostLinuxUpdateProgress: Codable, Equatable {
    let phase: HostLinuxUpdatePhase
    let detail: String
}

enum HostLinuxRestartPhase: String, Equatable {
    case waiting
    case issuing
    case waitingForOffline
    case waitingForOnline
    case verifying
    case succeeded
    case offline
    case failed

    var isTerminal: Bool {
        switch self {
        case .succeeded, .offline, .failed: true
        case .waiting, .issuing, .waitingForOffline, .waitingForOnline, .verifying: false
        }
    }
}

struct HostLinuxRestartProgress: Equatable {
    let phase: HostLinuxRestartPhase
    let detail: String
}

struct PersistedLinuxUpdateBatch: Codable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let targetHostIDs: [String]
    let startedAt: Date
    var progress: [String: HostLinuxUpdateProgress]
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        targetHostIDs: [String],
        startedAt: Date = Date(),
        progress: [String: HostLinuxUpdateProgress],
        finishedAt: Date? = nil
    ) {
        schemaVersion = 1
        self.id = id
        self.targetHostIDs = targetHostIDs
        self.startedAt = startedAt
        self.progress = progress
        self.finishedAt = finishedAt
    }
}

private struct PersistedLinuxUpdateStatuses: Codable {
    let schemaVersion: Int
    let snapshots: [String: LinuxUpdateSnapshot]
}

enum LinuxUpdateStore {
    private static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fleetlight", isDirectory: true)
    }

    private static var statusURL: URL {
        directoryURL.appendingPathComponent("linux-update-status.json")
    }

    private static var batchURL: URL {
        directoryURL.appendingPathComponent("linux-update-batch.json")
    }

    static func loadSnapshots() -> [String: LinuxUpdateSnapshot] {
        guard let data = try? Data(contentsOf: statusURL),
              let status = try? JSONDecoder().decode(PersistedLinuxUpdateStatuses.self, from: data),
              status.schemaVersion == 1 else { return [:] }
        return status.snapshots
    }

    static func saveSnapshots(_ snapshots: [String: LinuxUpdateSnapshot]) {
        let status = PersistedLinuxUpdateStatuses(schemaVersion: 1, snapshots: snapshots)
        guard let data = try? JSONEncoder().encode(status) else { return }
        save(data, to: statusURL)
    }

    static func loadBatch() -> PersistedLinuxUpdateBatch? {
        guard let data = try? Data(contentsOf: batchURL),
              let batch = try? JSONDecoder().decode(PersistedLinuxUpdateBatch.self, from: data),
              batch.schemaVersion == 1 else { return nil }
        return batch
    }

    static func saveBatch(_ batch: PersistedLinuxUpdateBatch) {
        guard let data = try? JSONEncoder().encode(batch) else { return }
        save(data, to: batchURL)
    }

    private static func save(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
