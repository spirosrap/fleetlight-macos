import Foundation

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
        var payload: [String: String] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": event,
        ]
        if let host { payload["host"] = host }
        if let detail { payload["detail"] = detail }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data(line.utf8))
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            return
        }
    }
}
