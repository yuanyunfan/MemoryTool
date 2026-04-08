import SwiftUI
import MemoryCore

@main
struct MemoryToolApp: App {
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue
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
        } catch {
            fatalError("Failed to initialize database at \(dbPath): \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: MemoryViewModel(service: memoryService))
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
            let memories = try memoryService.listMemories(limit: 100, offset: 0)
            let data = try JSONEncoder().encode(memories)
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
            let memories = try JSONDecoder().decode([Memory].self, from: data)
            for memory in memories {
                try memoryService.createMemory(
                    content: memory.content,
                    category: memory.category,
                    source: memory.source,
                    metadata: memory.metadata
                )
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
