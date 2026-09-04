import Foundation

enum PasswordStoreError: LocalizedError {
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        }
    }
}

enum PasswordStore {
    static let passwordLength = 8
    static let configFileName = "config.json"

    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

    private struct Config: Codable {
        let password: String
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mac-vnc-server", isDirectory: true)
            .appendingPathComponent(configFileName)
    }

    static func loadOrCreate() throws -> String {
        try loadOrCreate(in: configURL.deletingLastPathComponent())
    }

    static func loadOrCreate(in directoryURL: URL) throws -> String {
        let fileManager = FileManager.default
        try ensureDirectory(directoryURL, fileManager: fileManager)

        let fileURL = directoryURL.appendingPathComponent(configFileName)
        if fileManager.fileExists(atPath: fileURL.path) {
            return try load(from: fileURL, fileManager: fileManager)
        }

        let password = generatePassword()
        let data = try encodedConfig(password: password)
        let temporaryURL = directoryURL
            .appendingPathComponent(".\(configFileName).\(UUID().uuidString).tmp")

        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        do {
            try data.write(to: temporaryURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path
            )
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        } catch {
            if fileManager.fileExists(atPath: fileURL.path) {
                return try load(from: fileURL, fileManager: fileManager)
            }
            throw error
        }

        return password
    }

    private static func ensureDirectory(_ directoryURL: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }

        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directoryURL.path
        )
    }

    private static func load(from fileURL: URL, fileManager: FileManager) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw PasswordStoreError.invalidConfiguration(
                "could not decode \(fileURL.path): \(error.localizedDescription)"
            )
        }

        guard isValid(password: config.password) else {
            throw PasswordStoreError.invalidConfiguration(
                "\(fileURL.path) must contain an ASCII password of exactly \(passwordLength) characters"
            )
        }

        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
        return config.password
    }

    private static func encodedConfig(password: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Config(password: password))
    }

    private static func generatePassword() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<passwordLength).map { _ in
            alphabet[Int.random(in: alphabet.indices, using: &generator)]
        })
    }

    private static func isValid(password: String) -> Bool {
        password.utf8.count == passwordLength && password.allSatisfy { alphabet.contains($0) }
    }
}
