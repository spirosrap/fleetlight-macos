import Foundation
import FleetlightCore

actor MetricHistoryStore {
    static let shared = MetricHistoryStore()

    private let fileURL: URL
    private var samples: [MetricSample]
    private var batchesSinceCompaction = 0

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Fleetlight", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("metrics.jsonl")
        samples = Self.readSamples(from: fileURL)
    }

    func recent(hours: Double = 24, now: Date = Date()) -> [MetricSample] {
        prune(now: now)
        let cutoff = now.addingTimeInterval(-hours * 3_600)
        return samples.filter { $0.timestamp >= cutoff }
    }

    func append(
        snapshots: [String: HostSnapshot],
        recentHours: Double = 24,
        now: Date = Date()
    ) -> [MetricSample] {
        let batch = snapshots.keys.sorted().compactMap { hostID -> MetricSample? in
            guard let snapshot = snapshots[hostID] else { return nil }
            return MetricSample(hostID: hostID, snapshot: snapshot, timestamp: now)
        }

        guard !batch.isEmpty else { return recent(hours: recentHours, now: now) }
        samples.append(contentsOf: batch)
        appendToDisk(batch)
        prune(now: now)
        batchesSinceCompaction += 1

        if batchesSinceCompaction >= 60 {
            compact()
            batchesSinceCompaction = 0
        }

        return recent(hours: recentHours, now: now)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-7 * 24 * 3_600)
        samples.removeAll { $0.timestamp < cutoff }
    }

    private func appendToDisk(_ batch: [MetricSample]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = batch.compactMap { sample -> Data? in
            guard let data = try? encoder.encode(sample) else { return nil }
            var line = data
            line.append(0x0A)
            return line
        }.reduce(into: Data(), { $0.append($1) })

        guard !payload.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: payload)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } catch {
            return
        }
    }

    private func compact() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = samples.compactMap { sample -> Data? in
            guard let data = try? encoder.encode(sample) else { return nil }
            var line = data
            line.append(0x0A)
            return line
        }.reduce(into: Data(), { $0.append($1) })
        try? payload.write(to: fileURL, options: .atomic)
    }

    private static func readSamples(from url: URL) -> [MetricSample] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(MetricSample.self, from: Data(line))
        }
    }
}
