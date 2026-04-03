import SwiftUI
import MemoryCore

/// Right column: memory detail view with editing support.
struct MemoryDetailView: View {
    @Bindable var viewModel: MemoryViewModel

    // Editing state
    @State private var editContent: String = ""
    @State private var editCategory: String = ""
    @State private var editSource: String = ""
    @State private var editMetadata: String = ""
    @State private var memoryTags: [Tag] = []
    @State private var newTagText: String = ""
    @State private var showMetadata: Bool = false
    @State private var hasChanges: Bool = false
    @State private var showDeleteAlert: Bool = false

    // Track which memory we're editing
    @State private var loadedMemoryId: String?

    /// The currently selected memory, looked up from the view model.
    private var selectedMemory: Memory? {
        guard let id = viewModel.selectedMemoryId else { return nil }
        return viewModel.memories.first(where: { $0.id == id })
    }

    var body: some View {
        // Use a stable view identity so polling doesn't rebuild TextEditor
        VStack {
            if viewModel.selectedMemoryId != nil, selectedMemory != nil {
                detailContent
            } else {
                placeholderView
            }
        }
        .onChange(of: viewModel.selectedMemoryId) {
            loadMemoryData()
        }
        .onAppear {
            loadMemoryData()
        }
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        ContentUnavailableView {
            Label("Select a Memory", systemImage: "text.document")
        } description: {
            Text("Choose a memory from the list to view its details.")
        }
    }

    // MARK: - Detail Content

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                Divider()
                contentSection
                Divider()
                tagsSection
                Divider()
                sourceSection
                metadataSection
                Divider()
                actionButtons
            }
            .padding()
        }
        .alert("Delete Memory", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = viewModel.selectedMemoryId {
                    viewModel.deleteMemory(id: id)
                }
            }
        } message: {
            Text("Are you sure you want to delete this memory? This action cannot be undone.")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Category")
                    .font(.headline)
                if hasChanges {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                        .help("Unsaved changes")
                }
            }

            Picker("Category", selection: $editCategory) {
                ForEach(allCategories, id: \.self) { cat in
                    Text(cat).tag(cat)
                }
            }
            .labelsHidden()
            .onChange(of: editCategory) { markChanged() }

            if let memory = selectedMemory {
                HStack(spacing: 16) {
                    Label(DateFormatters.fullString(from: memory.createdAt), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label(DateFormatters.relativeString(from: memory.updatedAt), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Content

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Content")
                .font(.headline)

            TextEditor(text: $editContent)
                .font(.body)
                .frame(minHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: editContent) { markChanged() }
        }
    }

    // MARK: - Tags

    private var tagsSection: some View {
        let memoryId = viewModel.selectedMemoryId ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.headline)

            FlowLayout(spacing: 6) {
                ForEach(memoryTags) { tag in
                    HStack(spacing: 4) {
                        Text(tag.name)
                            .font(.caption)
                        Button {
                            removeTag(tag, from: memoryId)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.15))
                    .clipShape(Capsule())
                }
            }

            HStack {
                TextField("Add tag…", text: $newTagText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTag(to: memoryId) }

                Button("Add") { addTag(to: memoryId) }
                    .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source")
                .font(.headline)

            TextField("Source (optional)", text: $editSource)
                .textFieldStyle(.roundedBorder)
                .onChange(of: editSource) { markChanged() }
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Metadata", isExpanded: $showMetadata) {
                TextEditor(text: $editMetadata)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: editMetadata) { markChanged() }
            }
            .font(.headline)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack {
            Button("Save Changes") {
                if let memory = selectedMemory {
                    saveChanges(for: memory)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasChanges)

            Spacer()

            Button("Delete", role: .destructive) {
                showDeleteAlert = true
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    private var allCategories: [String] {
        var cats = Set(viewModel.categories)
        cats.insert("general")
        cats.insert(editCategory)
        return cats.sorted()
    }

    private func loadMemoryData() {
        guard let memoryId = viewModel.selectedMemoryId,
              let memory = viewModel.memories.first(where: { $0.id == memoryId }) else {
            return
        }

        if loadedMemoryId != memoryId {
            // Switching to a different memory — full reload
            loadedMemoryId = memoryId
            editContent = memory.content
            editCategory = memory.category
            editSource = memory.source ?? ""
            editMetadata = memory.metadata ?? ""
            memoryTags = viewModel.getTagsForMemory(id: memory.id)
            newTagText = ""
            hasChanges = false
            showMetadata = memory.metadata != nil && !memory.metadata!.isEmpty
        }
        // If same memory: do nothing here.
        // Tags refresh is handled by the polling via loadSidebarData.
    }

    private func markChanged() {
        guard let memory = selectedMemory else { return }
        hasChanges = editContent != memory.content
            || editCategory != memory.category
            || editSource != (memory.source ?? "")
            || editMetadata != (memory.metadata ?? "")
    }

    private func saveChanges(for memory: Memory) {
        var updated = memory
        updated.content = editContent
        updated.category = editCategory
        updated.source = editSource.isEmpty ? nil : editSource
        updated.metadata = editMetadata.isEmpty ? nil : editMetadata
        viewModel.updateMemory(updated)
        loadedMemoryId = nil // Force reload after save
        loadMemoryData()
    }

    private func addTag(to memoryId: String) {
        let tagName = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tagName.isEmpty else { return }
        viewModel.addTags(to: memoryId, tags: [tagName])
        memoryTags = viewModel.getTagsForMemory(id: memoryId)
        newTagText = ""
    }

    private func removeTag(_ tag: Tag, from memoryId: String) {
        viewModel.removeTags(from: memoryId, tags: [tag.name])
        memoryTags = viewModel.getTagsForMemory(id: memoryId)
    }
}

// MARK: - Flow Layout for Tags

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct ArrangementResult {
        var positions: [CGPoint]
        var size: CGSize
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> ArrangementResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
            totalHeight = max(totalHeight, currentY + lineHeight)
        }

        return ArrangementResult(
            positions: positions,
            size: CGSize(width: totalWidth, height: totalHeight)
        )
    }
}
