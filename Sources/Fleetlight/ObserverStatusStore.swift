import Foundation
import FleetlightCore

enum ObserverStatusStore {
    private static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fleetlight", isDirectory: true)
    }

    static var statusURL: URL {
        directoryURL.appendingPathComponent("observer-status.json")
    }

    static func save(_ snapshot: ObserverStatusSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: statusURL, options: .atomic)
    }
}
