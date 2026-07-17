import CryptoKit
import Foundation
import FleetlightCore
import Security

struct MobileControlPairingChallenge: Sendable {
    let codeHash: Data
    let expiresAt: Date
    var failedAttempts: Int
}

enum MobileControlPairingValidationError: Error, Equatable {
    case unavailable
    case expired
    case invalid
    case rateLimited
}

struct MobileControlPairedCredential: Codable, Equatable, Sendable {
    let deviceId: String
    let deviceName: String
    let tailscaleLogin: String
    let tokenHash: Data
    let pairedAt: Date
}

enum MobileControlCredentialError: Error {
    case randomGenerationFailed
    case keychain(OSStatus)
    case corruptKeychainData
}

enum MobileControlCrypto {
    static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw MobileControlCredentialError.randomGenerationFailed }
        return Data(bytes)
    }

    static func randomPairingCode() throws -> String {
        // Rejection sampling avoids modulo bias in the eight decimal digits.
        let maximumAccepted = UInt32.max - (UInt32.max % 100_000_000)
        while true {
            let data = try randomBytes(count: MemoryLayout<UInt32>.size)
            let value = data.withUnsafeBytes { rawBuffer -> UInt32 in
                rawBuffer.loadUnaligned(as: UInt32.self)
            }
            guard value < maximumAccepted else { continue }
            return String(format: "%08u", value % 100_000_000)
        }
    }

    static func token() throws -> String {
        try randomBytes(count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ value: String) -> Data {
        Data(SHA256.hash(data: Data(value.utf8)))
    }

    static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

final class MobileControlCredentialStore: @unchecked Sendable {
    static let shared = MobileControlCredentialStore()

    private let lock = NSLock()
    private let service = "\(Bundle.main.bundleIdentifier ?? "app.fleetlight.private").mobile-control"
    private let account = "paired-devices-v1"

    private init() {}

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return (try? loadUnlocked().count) ?? 0
    }

    func issue(
        deviceId: String,
        deviceName: String,
        tailscaleLogin: String,
        pairedAt: Date = Date()
    ) throws -> String {
        let token = try MobileControlCrypto.token()
        let credential = MobileControlPairedCredential(
            deviceId: deviceId,
            deviceName: deviceName,
            tailscaleLogin: tailscaleLogin,
            tokenHash: MobileControlCrypto.hash(token),
            pairedAt: pairedAt
        )

        lock.lock()
        defer { lock.unlock() }
        var credentials = try loadUnlocked()
        credentials.removeAll { $0.deviceId == deviceId }
        credentials.append(credential)
        try saveUnlocked(credentials)
        return token
    }

    func authenticate(authorizationHeader: String?) -> MobileControlPairedCredential? {
        guard let authorizationHeader else { return nil }
        let components = authorizationHeader.split(separator: " ", maxSplits: 1).map(String.init)
        guard components.count == 2,
              components[0].caseInsensitiveCompare("Bearer") == .orderedSame,
              !components[1].isEmpty else { return nil }
        let candidateHash = MobileControlCrypto.hash(components[1])

        lock.lock()
        defer { lock.unlock() }
        guard let credentials = try? loadUnlocked() else { return nil }
        // Evaluate every stored hash so authentication time does not reveal its index.
        var match: MobileControlPairedCredential?
        for credential in credentials {
            if MobileControlCrypto.constantTimeEqual(candidateHash, credential.tokenHash) {
                match = credential
            }
        }
        return match
    }

    func revokeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MobileControlCredentialError.keychain(status)
        }
    }

    private func loadUnlocked() throws -> [MobileControlPairedCredential] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw MobileControlCredentialError.keychain(status) }
        guard let data = result as? Data,
              let credentials = try? decoder.decode([MobileControlPairedCredential].self, from: data) else {
            throw MobileControlCredentialError.corruptKeychainData
        }
        return credentials
    }

    private func saveUnlocked(_ credentials: [MobileControlPairedCredential]) throws {
        let data = try encoder.encode(credentials)
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw MobileControlCredentialError.keychain(updateStatus)
        }

        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw MobileControlCredentialError.keychain(addStatus) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct PersistedMobileControlJobs: Codable {
    let schemaVersion: Int
    let jobs: [MobileControlJob]
}

struct MobileControlJobJournalLoad: Sendable {
    let jobs: [MobileControlJob]
    let isAvailable: Bool
}

enum MobileControlJobStore {
    private static var fileURL: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.fleetlight.private"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fleetlight", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("mobile-control-jobs.json")
    }

    static func load() -> MobileControlJobJournalLoad {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MobileControlJobJournalLoad(jobs: [], isAvailable: true)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return MobileControlJobJournalLoad(jobs: [], isAvailable: false)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let journal = try? decoder.decode(PersistedMobileControlJobs.self, from: data),
              journal.schemaVersion == 1 else {
            return MobileControlJobJournalLoad(jobs: [], isAvailable: false)
        }
        return MobileControlJobJournalLoad(jobs: journal.jobs, isAvailable: true)
    }

    @discardableResult
    static func save(_ jobs: [MobileControlJob]) -> Bool {
        do {
            try saveDurably(jobs)
            return true
        } catch {
            return false
        }
    }

    static func saveDurably(_ jobs: [MobileControlJob]) throws {
        // Keep the complete request-ID journal: evicting an old UUID would allow
        // a delayed replay to start the destructive operation again.
        let journal = PersistedMobileControlJobs(
            schemaVersion: 1,
            jobs: jobs.sorted { $0.createdAt > $1.createdAt }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private struct PersistedMobileControlChecks: Codable {
    let schemaVersion: Int
    let checks: [MobileControlCheck]
}

struct MobileControlCheckJournalLoad: Sendable {
    let checks: [MobileControlCheck]
    let isAvailable: Bool
}

enum MobileControlCheckStore {
    private static var fileURL: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.fleetlight.public"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fleetlight", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("mobile-control-checks.json")
    }

    static func load() -> MobileControlCheckJournalLoad {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MobileControlCheckJournalLoad(checks: [], isAvailable: true)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return MobileControlCheckJournalLoad(checks: [], isAvailable: false)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let journal = try? decoder.decode(PersistedMobileControlChecks.self, from: data),
              journal.schemaVersion == 1 else {
            return MobileControlCheckJournalLoad(checks: [], isAvailable: false)
        }
        return MobileControlCheckJournalLoad(
            checks: MobileControlCheckRetention.retained(journal.checks),
            isAvailable: true
        )
    }

    @discardableResult
    static func save(_ checks: [MobileControlCheck]) -> Bool {
        do {
            try saveDurably(checks)
            return true
        } catch {
            return false
        }
    }

    static func saveDurably(_ checks: [MobileControlCheck]) throws {
        // Live checks are read-only, so a bounded replay window prevents journal growth
        // without risking a repeated install or restart after an old entry is evicted.
        let journal = PersistedMobileControlChecks(
            schemaVersion: 1,
            checks: MobileControlCheckRetention.retained(checks)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

struct MobileControlHTTPResponse: Sendable {
    let statusCode: Int
    let reason: String
    let body: Data
    let contentType: String

    init(statusCode: Int, reason: String, body: Data = Data(), contentType: String = "application/json") {
        self.statusCode = statusCode
        self.reason = reason
        self.body = body
        self.contentType = contentType
    }
}
