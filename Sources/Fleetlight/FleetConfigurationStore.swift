import Foundation
import FleetlightCore

struct FleetConfigurationLoadResult {
    let configuration: FleetConfiguration
    let notice: String?
}

enum FleetConfigurationStore {
    static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fleetlight", isDirectory: true)
    }

    static var configurationURL: URL {
        directoryURL.appendingPathComponent("fleet.json")
    }

    static func loadOrCreate() -> FleetConfigurationLoadResult {
        do {
            let url = try ensureConfigurationExists()
            return FleetConfigurationLoadResult(configuration: try load(from: url), notice: nil)
        } catch {
            return FleetConfigurationLoadResult(
                configuration: .default,
                notice: "fleet.json could not be loaded: \(error.localizedDescription)"
            )
        }
    }

    static func load() throws -> FleetConfiguration {
        try load(from: ensureConfigurationExists())
    }

    @discardableResult
    static func ensureConfigurationExists() throws -> URL {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: configurationURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(FleetConfiguration.default)
            try data.write(to: configurationURL, options: .atomic)
        }
        return configurationURL
    }

    private static func load(from url: URL) throws -> FleetConfiguration {
        let configuration = try JSONDecoder().decode(
            FleetConfiguration.self,
            from: Data(contentsOf: url)
        )
        let errors = configuration.validationErrors
        guard errors.isEmpty else {
            throw ConfigurationError.invalid(errors.joined(separator: "; "))
        }
        return configuration
    }
}

private enum ConfigurationError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(detail): "Invalid configuration: \(detail)"
        }
    }
}
