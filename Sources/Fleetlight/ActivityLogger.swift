import Foundation

struct ActivityLogEntry: Sendable {
    let timestamp: Date
    let event: String
    let host: String?
    let detail: String?

    init(timestamp: Date = Date(), event: String, host: String? = nil, detail: String? = nil) {
        self.timestamp = timestamp
        self.event = event
        self.host = host
        self.detail = detail
    }
}

actor ActivityLogger {
    static let shared = ActivityLogger()

    let logURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Fleetlight", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("activity.jsonl")
    }

    func append(event: String, host: String? = nil, detail: String? = nil) {
        append([ActivityLogEntry(event: event, host: host, detail: detail)])
    }

    func append(_ entries: [ActivityLogEntry]) {
        guard !entries.isEmpty else { return }
        let formatter = ISO8601DateFormatter()
        let payload = entries.reduce(into: Data()) { output, entry in
            var object: [String: String] = [
                "timestamp": formatter.string(from: entry.timestamp),
                "event": entry.event,
            ]
            if let host = entry.host { object["host"] = host }
            if let detail = entry.detail { object["detail"] = detail }
            guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            line.append(0x0A)
            output.append(line)
        }
        guard !payload.isEmpty else { return }

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: payload)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } catch {
            return
        }
    }
}
