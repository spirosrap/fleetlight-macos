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

    @discardableResult
    static func save(_ snapshot: ObserverStatusSnapshot) -> Bool {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: statusURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
