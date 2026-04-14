import SwiftUI
import MemoryCore

@main
struct MemoryToolApp: App {
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue
    @State private var viewModel: MemoryViewModel
    private let memoryService: MemoryService

    private var colorScheme: ColorScheme? {
        (AppearanceMode(rawValue: appearanceMode) ?? .system).colorScheme
    }

    init() {
        // Initialize database at shared path with MCP server
        let dbDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".memorytool")
        let dbPath = dbDir.appendingPathComponent("memory.db").path

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: dbDir,
            withIntermediateDirectories: true
        )

        do {
            let database = try AppDatabase.create(path: dbPath)
            // GUI doesn't need embedding service (MCP handles it)
            self.memoryService = MemoryService(database: database)
            self._viewModel = State(initialValue: MemoryViewModel(service: self.memoryService))
        } catch {
            fatalError("Failed to initialize database at \(dbPath): \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Export Memories…") {
                    exportMemories()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Import Memories…") {
                    importMemories()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }

    // MARK: - Export / Import

    private func exportMemories() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "memories-export.json"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try DataExporter.exportToJSON(service: memoryService)
            try data.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func importMemories() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let result = try DataExporter.importFromJSON(data: data, service: memoryService)

            let alert = NSAlert()
            alert.messageText = "Import Complete"
            var info = "Imported: \(result.imported), Skipped (already exist): \(result.skipped)"
            if !result.errors.isEmpty {
                info += "\nErrors: \(result.errors.joined(separator: "\n"))"
            }
            alert.informativeText = info
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
