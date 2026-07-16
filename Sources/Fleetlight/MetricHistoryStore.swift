import Foundation
import FleetlightCore

actor MetricHistoryStore {
    static let shared = MetricHistoryStore()

    private let fileURL: URL
    private let compactionStampURL: URL
    private var samples: [MetricSample] = []
    private var isLoaded = false
    private var needsCompaction = false
    private var lastCompactionAt: Date

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Fleetlight", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("metrics.jsonl")
        compactionStampURL = directory.appendingPathComponent("metrics-compaction.stamp")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: compactionStampURL.path),
           let modifiedAt = attributes[.modificationDate] as? Date {
            lastCompactionAt = modifiedAt
        } else {
            lastCompactionAt = Date()
            FileManager.default.createFile(atPath: compactionStampURL.path, contents: Data())
        }
    }

    func recent(hours: Double = 24, now: Date = Date()) -> [MetricSample] {
        ensureLoaded()
        if prune(now: now) { needsCompaction = true }
        let cutoff = now.addingTimeInterval(-hours * 3_600)
        return samples.filter { $0.timestamp >= cutoff }
    }

    func append(
        snapshots: [String: HostSnapshot],
        now: Date = Date()
    ) -> [MetricSample] {
        ensureLoaded()
        let batch = snapshots.keys.sorted().compactMap { hostID -> MetricSample? in
            guard let snapshot = snapshots[hostID] else { return nil }
            return MetricSample(hostID: hostID, snapshot: snapshot, timestamp: now)
        }

        guard !batch.isEmpty else { return [] }
        samples.append(contentsOf: batch)
        appendToDisk(batch)
        if prune(now: now) { needsCompaction = true }

        if needsCompaction,
           now.timeIntervalSince(lastCompactionAt) >= 6 * 3_600,
           compact() {
            needsCompaction = false
            lastCompactionAt = now
            try? Data().write(to: compactionStampURL, options: .atomic)
        }

        return batch
    }

    private func ensureLoaded() {
        guard !isLoaded else { return }
        samples = Self.readSamples(from: fileURL)
        isLoaded = true
    }

    @discardableResult
    private func prune(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-7 * 24 * 3_600)
        let previousCount = samples.count
        samples.removeAll { $0.timestamp < cutoff }
        return samples.count != previousCount
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

    private func compact() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = samples.compactMap { sample -> Data? in
            guard let data = try? encoder.encode(sample) else { return nil }
            var line = data
            line.append(0x0A)
            return line
        }.reduce(into: Data(), { $0.append($1) })
        do {
            try payload.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
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
