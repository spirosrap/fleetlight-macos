import Foundation

enum HostCodexUpdatePhase: String, Codable, Equatable {
    case notAttempted
    case updating
    case succeeded
    case offline
    case failed

    var isTerminal: Bool {
        switch self {
        case .succeeded, .offline, .failed:
            true
        case .notAttempted, .updating:
            false
        }
    }
}

struct HostCodexUpdateProgress: Codable, Equatable {
    let phase: HostCodexUpdatePhase
    let detail: String
}

struct PersistedCodexUpdateBatch: Codable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let targetHostIDs: [String]
    let startedAt: Date
    var progress: [String: HostCodexUpdateProgress]
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        targetHostIDs: [String],
        startedAt: Date = Date(),
        progress: [String: HostCodexUpdateProgress],
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

enum CodexUpdateBatchStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fleetlight", isDirectory: true)
            .appendingPathComponent("codex-update-batch.json")
    }

    static func load() -> PersistedCodexUpdateBatch? {
        guard let data = try? Data(contentsOf: fileURL),
              let batch = try? JSONDecoder().decode(PersistedCodexUpdateBatch.self, from: data),
              batch.schemaVersion == 1 else { return nil }
        return batch
    }

    static func save(_ batch: PersistedCodexUpdateBatch) {
        guard let data = try? JSONEncoder().encode(batch) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
