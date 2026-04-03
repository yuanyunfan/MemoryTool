import Testing
import Foundation
@testable import MemoryCore

// MARK: - Config Snippet Generation

@Test func generateConfigSnippet() {
    let snippet = MCPConfigInstaller.generateConfigSnippet(binaryPath: "/usr/local/bin/MemoryMCP")
    #expect(snippet.contains("memory-tool"))
    #expect(snippet.contains("/usr/local/bin/MemoryMCP"))
    #expect(snippet.contains("\"command\""))
}

// MARK: - Install to Fresh File

@Test func installCreatesNewSettings() throws {
    let tmp = NSTemporaryDirectory() + "mcp_test_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let settingsPath = tmp + "/settings.json"

    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let result = try MCPConfigInstaller.install(
        binaryPath: "/test/MemoryMCP",
        settingsPath: settingsPath
    )

    #expect(result.contains("memory-tool"))
    #expect(FileManager.default.fileExists(atPath: settingsPath))

    // Verify JSON structure
    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let servers = json["mcpServers"] as! [String: Any]
    let entry = servers["memory-tool"] as! [String: Any]
    #expect(entry["command"] as? String == "/test/MemoryMCP")
}

// MARK: - Install Preserves Existing Config

@Test func installPreservesExistingServers() throws {
    let tmp = NSTemporaryDirectory() + "mcp_test_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let settingsPath = tmp + "/settings.json"

    defer { try? FileManager.default.removeItem(atPath: tmp) }

    // Write existing config with another MCP server
    let existing: [String: Any] = [
        "mcpServers": [
            "other-server": [
                "command": "/usr/bin/other",
                "args": ["--flag"],
            ]
        ],
        "someOtherKey": "preserved",
    ]
    let existingData = try JSONSerialization.data(withJSONObject: existing, options: .prettyPrinted)
    try existingData.write(to: URL(fileURLWithPath: settingsPath))

    try MCPConfigInstaller.install(
        binaryPath: "/test/MemoryMCP",
        settingsPath: settingsPath
    )

    // Verify both servers exist and other config is preserved
    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    #expect(json["someOtherKey"] as? String == "preserved")

    let servers = json["mcpServers"] as! [String: Any]
    #expect(servers["other-server"] != nil)
    #expect(servers["memory-tool"] != nil)
}

// MARK: - Install Updates Existing Entry

@Test func installUpdatesExistingEntry() throws {
    let tmp = NSTemporaryDirectory() + "mcp_test_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let settingsPath = tmp + "/settings.json"

    defer { try? FileManager.default.removeItem(atPath: tmp) }

    // Install with old path
    try MCPConfigInstaller.install(binaryPath: "/old/MemoryMCP", settingsPath: settingsPath)

    // Install again with new path — should update, not duplicate
    try MCPConfigInstaller.install(binaryPath: "/new/MemoryMCP", settingsPath: settingsPath)

    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let servers = json["mcpServers"] as! [String: Any]
    let entry = servers["memory-tool"] as! [String: Any]
    #expect(entry["command"] as? String == "/new/MemoryMCP")
}

// MARK: - isInstalled

@Test func isInstalledReturnsFalseWhenNoFile() {
    let path = NSTemporaryDirectory() + "nonexistent_\(UUID().uuidString)/settings.json"
    #expect(MCPConfigInstaller.isInstalled(settingsPath: path) == false)
}

@Test func isInstalledReturnsTrueAfterInstall() throws {
    let tmp = NSTemporaryDirectory() + "mcp_test_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let settingsPath = tmp + "/settings.json"

    defer { try? FileManager.default.removeItem(atPath: tmp) }

    try MCPConfigInstaller.install(binaryPath: "/test/MemoryMCP", settingsPath: settingsPath)
    #expect(MCPConfigInstaller.isInstalled(settingsPath: settingsPath) == true)
}

// MARK: - Uninstall

@Test func uninstallRemovesEntry() throws {
    let tmp = NSTemporaryDirectory() + "mcp_test_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let settingsPath = tmp + "/settings.json"

    defer { try? FileManager.default.removeItem(atPath: tmp) }

    try MCPConfigInstaller.install(binaryPath: "/test/MemoryMCP", settingsPath: settingsPath)
    #expect(MCPConfigInstaller.isInstalled(settingsPath: settingsPath) == true)

    try MCPConfigInstaller.uninstall(settingsPath: settingsPath)
    #expect(MCPConfigInstaller.isInstalled(settingsPath: settingsPath) == false)

    // File should still exist with valid JSON
    let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["mcpServers"] != nil)
}

@Test func uninstallNoopWhenNoFile() throws {
    let path = NSTemporaryDirectory() + "nonexistent_\(UUID().uuidString)/settings.json"
    // Should not throw even if no file
    // readSettingsFile returns [:] when file doesn't exist, but writeSettingsFile will
    // try to write — and that's fine, it creates the dir. Actually let's just check
    // that uninstall on a non-existent file doesn't crash.
    // The file doesn't exist → readSettingsFile returns [:] → no mcpServers → early return.
    try MCPConfigInstaller.uninstall(settingsPath: path)
}

// MARK: - installedBinaryPath

@Test func installedBinaryPathReturnsCorrectPath() throws {
    let tmp = NSTemporaryDirectory() + "mcp_test_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let settingsPath = tmp + "/settings.json"

    defer { try? FileManager.default.removeItem(atPath: tmp) }

    try MCPConfigInstaller.install(binaryPath: "/some/path/MemoryMCP", settingsPath: settingsPath)
    #expect(MCPConfigInstaller.installedBinaryPath(settingsPath: settingsPath) == "/some/path/MemoryMCP")
}

// MARK: - Error Cases

@Test func installThrowsWhenBinaryEmpty() {
    let settingsPath = NSTemporaryDirectory() + "mcp_test_\(UUID().uuidString)/settings.json"
    #expect(throws: ConfigInstallerError.self) {
        try MCPConfigInstaller.install(binaryPath: "", settingsPath: settingsPath)
    }
}

@Test func readInvalidJSONThrows() throws {
    let tmp = NSTemporaryDirectory() + "mcp_test_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let settingsPath = tmp + "/settings.json"

    defer { try? FileManager.default.removeItem(atPath: tmp) }

    // Write invalid JSON (an array, not an object)
    try "[1,2,3]".data(using: .utf8)!.write(to: URL(fileURLWithPath: settingsPath))

    #expect(throws: ConfigInstallerError.self) {
        try MCPConfigInstaller.install(binaryPath: "/test/MemoryMCP", settingsPath: settingsPath)
    }
}

// MARK: - Empty File Handling

@Test func installHandlesEmptyFile() throws {
    let tmp = NSTemporaryDirectory() + "mcp_test_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let settingsPath = tmp + "/settings.json"

    defer { try? FileManager.default.removeItem(atPath: tmp) }

    // Create an empty file
    FileManager.default.createFile(atPath: settingsPath, contents: Data())

    try MCPConfigInstaller.install(binaryPath: "/test/MemoryMCP", settingsPath: settingsPath)
    #expect(MCPConfigInstaller.isInstalled(settingsPath: settingsPath) == true)
}
