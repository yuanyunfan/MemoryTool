import Foundation

/// Manages Claude Code MCP server configuration for MemoryTool.
///
/// Reads and writes `~/.claude/settings.json` to register the MemoryMCP binary
/// as an MCP server. All operations preserve existing user configuration.
public struct MCPConfigInstaller: Sendable {

    // MARK: - Paths

    /// Claude Code settings.json default path.
    public static var claudeSettingsPath: String {
        NSHomeDirectory() + "/.claude/settings.json"
    }

    /// Attempts to locate the MemoryMCP binary in common locations.
    ///
    /// Search order:
    /// 1. `~/.memorytool/bin/MemoryMCP` (installed location)
    /// 2. SPM release build: `.build/release/MemoryMCP`
    /// 3. SPM debug build: `.build/debug/MemoryMCP`
    public static var mcpBinaryPath: String? {
        let candidates = [
            NSHomeDirectory() + "/.memorytool/bin/MemoryMCP",
            ".build/release/MemoryMCP",
            ".build/debug/MemoryMCP",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Configuration Key

    /// Key used inside `mcpServers`.
    public static let serverKey = "memory-tool"

    // MARK: - Install

    /// Installs MemoryMCP configuration into Claude Code settings.
    ///
    /// - Parameters:
    ///   - binaryPath: Explicit path to the MemoryMCP binary. If nil, auto-detects.
    ///   - settingsPath: Path to settings.json (override for testing).
    /// - Returns: A human-readable result description.
    @discardableResult
    public static func install(
        binaryPath: String? = nil,
        settingsPath: String? = nil
    ) throws -> String {
        let path = settingsPath ?? claudeSettingsPath
        let binary = binaryPath ?? mcpBinaryPath

        guard let binary, !binary.isEmpty else {
            throw ConfigInstallerError.binaryNotFound
        }

        var root = try readSettingsFile(at: path)

        // Ensure mcpServers dictionary exists
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]

        // Build the entry
        let entry: [String: Any] = [
            "command": binary,
            "args": [String](),
            "env": [String: String](),
        ]

        mcpServers[serverKey] = entry
        root["mcpServers"] = mcpServers

        try writeSettingsFile(root, to: path)

        let action = "Installed"
        return "\(action) \(serverKey) → \(binary) in \(path)"
    }

    // MARK: - Uninstall

    /// Removes the MemoryMCP entry from Claude Code settings.
    ///
    /// - Parameter settingsPath: Path to settings.json (override for testing).
    public static func uninstall(settingsPath: String? = nil) throws {
        let path = settingsPath ?? claudeSettingsPath
        var root = try readSettingsFile(at: path)

        guard var mcpServers = root["mcpServers"] as? [String: Any] else {
            return // nothing to remove
        }

        mcpServers.removeValue(forKey: serverKey)
        root["mcpServers"] = mcpServers

        try writeSettingsFile(root, to: path)
    }

    // MARK: - Query

    /// Checks whether the memory-tool entry exists in Claude Code settings.
    ///
    /// - Parameter settingsPath: Path to settings.json (override for testing).
    public static func isInstalled(settingsPath: String? = nil) -> Bool {
        let path = settingsPath ?? claudeSettingsPath
        guard let root = try? readSettingsFile(at: path),
              let mcpServers = root["mcpServers"] as? [String: Any]
        else {
            return false
        }
        return mcpServers[serverKey] != nil
    }

    /// Returns the currently configured binary path, or nil if not installed.
    ///
    /// - Parameter settingsPath: Path to settings.json (override for testing).
    public static func installedBinaryPath(settingsPath: String? = nil) -> String? {
        let path = settingsPath ?? claudeSettingsPath
        guard let root = try? readSettingsFile(at: path),
              let mcpServers = root["mcpServers"] as? [String: Any],
              let entry = mcpServers[serverKey] as? [String: Any],
              let command = entry["command"] as? String
        else {
            return nil
        }
        return command
    }

    // MARK: - Snippet

    /// Generates a JSON snippet that users can paste manually.
    public static func generateConfigSnippet(binaryPath: String) -> String {
        let escapedPath = jsonEscape(binaryPath)
        return """
        {
          "mcpServers": {
            "\(serverKey)": {
              "command": "\(escapedPath)",
              "args": [],
              "env": {}
            }
          }
        }
        """
    }

    /// Escapes a string for safe inclusion inside a JSON double-quoted value.
    ///
    /// Handles backslashes, double quotes, and control characters (U+0000–U+001F).
    private static func jsonEscape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for char in string {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if let ascii = char.asciiValue, ascii < 0x20 {
                    result += String(format: "\\u%04x", ascii)
                } else {
                    result.append(char)
                }
            }
        }
        return result
    }

    // MARK: - Private Helpers

    /// Reads an existing settings file or returns an empty dictionary if not found.
    static func readSettingsFile(at path: String) throws -> [String: Any] {
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else {
            return [:] // no file yet → start fresh
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        // Allow empty files
        guard !data.isEmpty else {
            return [:]
        }

        let json = try JSONSerialization.jsonObject(with: data)

        guard let dict = json as? [String: Any] else {
            throw ConfigInstallerError.invalidSettingsFormat
        }
        return dict
    }

    /// Writes the settings dictionary as pretty-printed JSON.
    static func writeSettingsFile(_ dict: [String: Any], to path: String) throws {
        let fm = FileManager.default

        // Create parent directory if needed
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )

        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// MARK: - Errors

public enum ConfigInstallerError: Error, LocalizedError {
    case binaryNotFound
    case invalidSettingsFormat

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "MemoryMCP binary not found. Build the project first or supply an explicit path."
        case .invalidSettingsFormat:
            "settings.json exists but is not a valid JSON object."
        }
    }
}
