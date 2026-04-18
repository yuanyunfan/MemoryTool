import Foundation
import Observation
import MemoryCore
import Combine

/// Main view model that manages all memory state and data operations.
@Observable
@MainActor
final class MemoryViewModel {
    // MARK: - Public State

    var memories: [Memory] = []
    var selectedMemoryId: String?
    var searchText: String = ""
    var selectedCategory: String?
    var selectedTag: String?
    var categories: [String] = []
    var tags: [Tag] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var totalCount: Int = 0

    // MARK: - Private

    private let service: MemoryService
    private var searchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastKnownCount: Int = -1

    // MARK: - Init

    init(service: MemoryService) {
        self.service = service
    }

    // MARK: - Auto Refresh

    /// Start polling the database for external changes (e.g., MCP server writes).
    /// Checks every 2 seconds if total count changed; if so, reloads everything.
    func startAutoRefresh() {
        stopAutoRefresh()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.checkForExternalChanges()
            }
        }
    }

    /// Stop the auto-refresh polling.
    func stopAutoRefresh() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Check if the database was modified externally and reload if needed.
    private func checkForExternalChanges() {
        do {
            let currentCount = try service.totalMemoryCount()
            let currentTags = try service.listAllTags()
            let currentCategories = try service.listCategories()

            let tagsChanged = currentTags.map(\.name) != tags.map(\.name)
            let categoriesChanged = currentCategories != categories
            let countChanged = currentCount != lastKnownCount

            if countChanged || tagsChanged || categoriesChanged {
                lastKnownCount = currentCount
                loadMemories()
                loadSidebarData()
            }
        } catch {
            // Silently ignore polling errors
        }
    }

    // MARK: - Loading

    /// Load memories based on current filters (category, tag, search text).
    func loadMemories() {
        isLoading = true
        errorMessage = nil

        do {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let tagFilter: [String]? = selectedTag.map { [$0] }
                memories = try service.searchMemories(
                    query: searchText,
                    category: selectedCategory,
                    tags: tagFilter,
                    limit: 100
                )
            } else if let tag = selectedTag {
                // Filter by tag: search with empty query falls back to list,
                // but we need tag filtering, so use searchMemories with a wildcard-ish approach
                memories = try service.searchMemories(
                    query: "",
                    category: selectedCategory,
                    tags: [tag],
                    limit: 100
                )
            } else {
                memories = try service.listMemories(
                    category: selectedCategory,
                    limit: 100,
                    offset: 0
                )
            }
            totalCount = try service.totalMemoryCount()
            lastKnownCount = totalCount
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Debounced search triggered by searchText changes.
    func searchDebounced() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            loadMemories()
        }
    }

    /// Load all categories and tags for the sidebar.
    func loadSidebarData() {
        do {
            categories = try service.listCategories()
            tags = try service.listAllTags()
            totalCount = try service.totalMemoryCount()
            lastKnownCount = totalCount
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - CRUD

    /// Create a new memory.
    @discardableResult
    func createMemory(
        content: String,
        category: String,
        tags: [String],
        source: String?,
        metadata: String?
    ) -> Memory? {
        do {
            let memory = try service.createMemory(
                content: content,
                category: category.isEmpty ? "general" : category,
                source: source?.isEmpty == true ? nil : source,
                tags: tags.isEmpty ? nil : tags,
                metadata: metadata?.isEmpty == true ? nil : metadata
            )
            loadMemories()
            loadSidebarData()
            return memory
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Update an existing memory.
    func updateMemory(_ memory: Memory) {
        do {
            _ = try service.updateMemory(
                id: memory.id,
                content: memory.content,
                category: memory.category,
                source: memory.source,
                metadata: memory.metadata
            )
            loadMemories()
            loadSidebarData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete a memory by ID.
    func deleteMemory(id: String) {
        do {
            _ = try service.deleteMemory(id: id)
            if selectedMemoryId == id {
                selectedMemoryId = nil
            }
            loadMemories()
            loadSidebarData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Get tags for a specific memory.
    func getTagsForMemory(id: String) -> [Tag] {
        (try? service.getTagsForMemory(id: id)) ?? []
    }

    /// Add tags to a memory.
    func addTags(to memoryId: String, tags: [String]) {
        do {
            try service.addTags(to: memoryId, tags: tags)
            loadSidebarData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Remove tags from a memory.
    func removeTags(from memoryId: String, tags: [String]) {
        do {
            try service.removeTags(from: memoryId, tags: tags)
            loadSidebarData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Count memories in a specific category.
    func countForCategory(_ category: String?) -> Int {
        if category == nil {
            return totalCount
        }
        return (try? service.countMemories(category: category)) ?? 0
    }

    // MARK: - Filters

    /// Select a category filter and reload.
    func selectCategory(_ category: String?) {
        selectedCategory = category
        selectedTag = nil
        loadMemories()
    }

    /// Select a tag filter and reload.
    func selectTag(_ tag: String?) {
        selectedTag = tag
        selectedCategory = nil
        loadMemories()
    }
}
