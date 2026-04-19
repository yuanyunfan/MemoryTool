import Foundation
import MCP
import MemoryCore

/// Handles MCP tool call dispatching to MemoryService.
///
/// This type is Sendable because MemoryService is a Sendable final class
/// with thread-safe GRDB-backed database access.
struct ToolHandler: Sendable {
    let service: MemoryService

    init(service: MemoryService) {
        self.service = service
    }

    /// Route a tool call to the appropriate handler.
    func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        switch params.name {
        case "remember":
            return try await handleRemember(params.arguments)
        case "recall":
            return try await handleRecall(params.arguments)
        case "forget":
            return try handleForget(params.arguments)
        case "update_memory":
            return try await handleUpdateMemory(params.arguments)
        case "list_categories":
            return try handleListCategories()
        case "get_memory":
            return try handleGetMemory(params.arguments)
        default:
            return .init(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    // MARK: - remember

    private func handleRemember(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let content = arguments?["content"]?.stringValue, !content.isEmpty else {
            return errorResult("Parameter 'content' is required and must not be empty.")
        }

        // Validate content size (100KB max)
        if content.utf8.count > 100 * 1024 {
            return errorResult("Content exceeds maximum size of 100KB.")
        }

        let category = arguments?["category"]?.stringValue ?? "general"
        let source = arguments?["source"]?.stringValue
        let userMetadata = arguments?["metadata"]?.stringValue
        let tags = extractTags(from: arguments)

        do {
            // Rely on createMemoryAsync's built-in deduplication to avoid
            // redundant embedding computation and double DB writes.
            let result = try await service.createMemoryAsync(
                content: content,
                category: category,
                source: source,
                tags: tags,
                metadata: userMetadata
            )

            if result.wasMerged {
                // Ensure tags are also merged for deduplicated memories
                if let tags, !tags.isEmpty {
                    try service.addTags(to: result.memory.id, tags: tags)
                }

                let response: [String: Any] = [
                    "id": result.memory.id,
                    "message": "Merged with existing similar memory.",
                    "deduplicated": true,
                ]
                return textResult(toJSON(response))
            } else {
                let response: [String: Any] = [
                    "id": result.memory.id,
                    "message": "Memory stored successfully.",
                ]
                return textResult(toJSON(response))
            }
        } catch {
            return errorResult("Failed to store memory: \(error.localizedDescription)")
        }
    }

    // MARK: - recall

    private func handleRecall(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        // Accept both "query" and "content" as parameter name (Claude sometimes confuses them)
        let query = arguments?["query"]?.stringValue
            ?? arguments?["content"]?.stringValue
            ?? ""

        let category = arguments?["category"]?.stringValue
        let tags = extractTags(from: arguments)
        var limit = arguments?["limit"]?.intValue ?? 10
        limit = min(max(limit, 1), 50)

        do {
            let memories = try await service.searchMemoriesAsync(
                query: query,
                category: category,
                tags: tags,
                limit: limit
            )

            // Batch fetch tags to avoid N+1 query
            let results: [[String: Any]] = try memories.map { memory in
                var entry: [String: Any] = [
                    "id": memory.id,
                    "content": memory.content,
                    "category": memory.category,
                    "createdAt": iso8601(memory.createdAt),
                ]
                if memory.accessCount > 0 {
                    entry["accessCount"] = memory.accessCount
                }
                let memoryTags = try service.getTagsForMemory(id: memory.id)
                if !memoryTags.isEmpty {
                    entry["tags"] = memoryTags.map(\.name)
                }
                return entry
            }

            return textResult(toJSON(results))
        } catch {
            return errorResult("Search failed: \(error.localizedDescription)")
        }
    }

    // MARK: - forget

    private func handleForget(_ arguments: [String: Value]?) throws -> CallTool.Result {
        guard let memoryId = arguments?["memory_id"]?.stringValue, !memoryId.isEmpty else {
            return errorResult("Parameter 'memory_id' is required.")
        }

        do {
            let deleted = try service.deleteMemory(id: memoryId)
            if deleted {
                return textResult("{\"message\": \"Memory deleted successfully.\"}")
            } else {
                return errorResult("Memory not found with ID: \(memoryId)")
            }
        } catch {
            return errorResult("Failed to delete memory: \(error.localizedDescription)")
        }
    }

    // MARK: - update_memory

    private func handleUpdateMemory(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let memoryId = arguments?["memory_id"]?.stringValue, !memoryId.isEmpty else {
            return errorResult("Parameter 'memory_id' is required.")
        }

        let content = arguments?["content"]?.stringValue
        let category = arguments?["category"]?.stringValue
        let source = arguments?["source"]?.stringValue
        let userMetadata = arguments?["metadata"]?.stringValue
        let tags = extractTags(from: arguments)

        // Validate content size if provided
        if let content, content.utf8.count > 100 * 1024 {
            return errorResult("Content exceeds maximum size of 100KB.")
        }

        do {
            guard let updated = try await service.updateMemoryAsync(
                id: memoryId,
                content: content,
                category: category,
                source: source,
                metadata: userMetadata
            ) else {
                return errorResult("Memory not found with ID: \(memoryId)")
            }

            // Replace tags if provided
            if let tags {
                let existingTags = try service.getTagsForMemory(id: memoryId)
                if !existingTags.isEmpty {
                    try service.removeTags(
                        from: memoryId,
                        tags: existingTags.map(\.name)
                    )
                }
                if !tags.isEmpty {
                    try service.addTags(to: memoryId, tags: tags)
                }
            }

            let response = try memoryToDict(updated)
            return textResult(toJSON(response))
        } catch {
            return errorResult("Failed to update memory: \(error.localizedDescription)")
        }
    }

    // MARK: - list_categories

    private func handleListCategories() throws -> CallTool.Result {
        do {
            let categoriesWithCounts = try service.listCategoriesWithCounts()

            let results: [[String: Any]] = categoriesWithCounts.map { item in
                [
                    "category": item.category,
                    "count": item.count,
                ]
            }

            return textResult(toJSON(results))
        } catch {
            return errorResult("Failed to list categories: \(error.localizedDescription)")
        }
    }

    // MARK: - get_memory

    private func handleGetMemory(_ arguments: [String: Value]?) throws -> CallTool.Result {
        guard let memoryId = arguments?["memory_id"]?.stringValue, !memoryId.isEmpty else {
            return errorResult("Parameter 'memory_id' is required.")
        }

        do {
            guard let memory = try service.getMemory(id: memoryId) else {
                return errorResult("Memory not found with ID: \(memoryId)")
            }

            let response = try memoryToDict(memory)
            return textResult(toJSON(response))
        } catch {
            return errorResult("Failed to retrieve memory: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func textResult(_ text: String) -> CallTool.Result {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    private func errorResult(_ message: String) -> CallTool.Result {
        .init(
            content: [.text(text: "{\"error\": \"\(escapeJSON(message))\"}", annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private func memoryToDict(_ memory: Memory) throws -> [String: Any] {
        var dict: [String: Any] = [
            "id": memory.id,
            "content": memory.content,
            "category": memory.category,
            "createdAt": iso8601(memory.createdAt),
            "updatedAt": iso8601(memory.updatedAt),
        ]
        if let source = memory.source {
            dict["source"] = source
        }
        if let metadata = memory.metadata {
            dict["metadata"] = metadata
        }
        if memory.accessCount > 0 {
            dict["accessCount"] = memory.accessCount
        }
        let tags = try service.getTagsForMemory(id: memory.id)
        if !tags.isEmpty {
            dict["tags"] = tags.map(\.name)
        }
        return dict
    }

    /// Extract tags array from MCP arguments.
    private func extractTags(from arguments: [String: Value]?) -> [String]? {
        guard let tagsValue = arguments?["tags"]?.arrayValue else { return nil }
        return tagsValue.compactMap { $0.stringValue }
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func toJSON(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .fragmentsAllowed]),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    private func toJSON(_ array: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys, .fragmentsAllowed]),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    private func escapeJSON(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
