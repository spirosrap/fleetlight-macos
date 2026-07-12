import Foundation
import FleetlightCore

actor IncidentStore {
    static let shared = IncidentStore()

    private let fileURL: URL
    private var events: [IncidentEvent]
    private var writesSinceCompaction = 0

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Fleetlight", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("incidents.jsonl")
        events = Self.readEvents(from: fileURL)
    }

    func recent(limit: Int = 100, now: Date = Date()) -> [IncidentEvent] {
        prune(now: now)
        return Array(events.suffix(limit)).reversed()
    }

    func append(_ event: IncidentEvent) -> [IncidentEvent] {
        events.append(event)
        appendToDisk(event)
        prune(now: event.timestamp)
        writesSinceCompaction += 1

        if writesSinceCompaction >= 50 {
            compact()
            writesSinceCompaction = 0
        }
        return recent(limit: 500, now: event.timestamp)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-30 * 24 * 3_600)
        events.removeAll { $0.timestamp < cutoff }
        if events.count > 500 {
            events.removeFirst(events.count - 500)
        }
    }

    private func appendToDisk(_ event: IncidentEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var payload = try? encoder.encode(event) else { return }
        payload.append(0x0A)

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
        let payload = events.compactMap { event -> Data? in
            guard var data = try? encoder.encode(event) else { return nil }
            data.append(0x0A)
            return data
        }.reduce(into: Data(), { $0.append($1) })
        try? payload.write(to: fileURL, options: .atomic)
    }

    private static func readEvents(from url: URL) -> [IncidentEvent] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(IncidentEvent.self, from: Data(line))
        }
    }
}
