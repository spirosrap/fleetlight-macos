import Foundation
import FleetlightCore

enum MobileFeedStore {
    private static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fleetlight", isDirectory: true)
            .appendingPathComponent("mobile", isDirectory: true)
    }

    static var feedURL: URL {
        directoryURL.appendingPathComponent("mobile-feed.json")
    }

    @discardableResult
    static func save(_ document: MobileFeedDocument) -> Bool {
        do {
            let data = try MobileFeedCodec.encode(document)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: feedURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: feedURL.path)
            return true
        } catch {
            return false
        }
    }
}
