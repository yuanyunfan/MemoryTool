import SwiftUI
import MemoryCore

/// Sheet for creating a new memory.
struct NewMemoryView: View {
    @Bindable var viewModel: MemoryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var content: String = ""
    @State private var category: String = "general"
    @State private var customCategory: String = ""
    @State private var tagInput: String = ""
    @State private var selectedTags: [String] = []
    @State private var source: String = ""
    @State private var useCustomCategory: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("New Memory")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Form content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    contentField
                    categoryField
                    tagsField
                    sourceField
                }
                .padding()
            }

            Divider()

            // Bottom buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    createMemory()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 500)
    }

    // MARK: - Content Field

    private var contentField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Content")
                .font(.headline)

            TextEditor(text: $content)
                .font(.body)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Category Field

    private var categoryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Category")
                .font(.headline)

            HStack {
                Picker("Category", selection: $category) {
                    Text("general").tag("general")
                    ForEach(viewModel.categories.filter { $0 != "general" }, id: \.self) { cat in
                        Text(cat).tag(cat)
                    }
                    Text("Custom…").tag("__custom__")
                }
                .labelsHidden()
                .onChange(of: category) {
                    useCustomCategory = (category == "__custom__")
                }

                if useCustomCategory {
                    TextField("Custom category", text: $customCategory)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: - Tags Field

    private var tagsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags")
                .font(.headline)

            // Selected tags chips
            if !selectedTags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(selectedTags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.caption)
                            Button {
                                selectedTags.removeAll { $0 == tag }
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
            }

            HStack {
                TextField("Add tag…", text: $tagInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTag() }

                Button("Add") { addTag() }
                    .disabled(tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Existing tags for quick selection
            if !viewModel.tags.isEmpty {
                HStack(spacing: 4) {
                    Text("Existing:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(viewModel.tags.prefix(10)) { tag in
                        Button(tag.name) {
                            if !selectedTags.contains(tag.name) {
                                selectedTags.append(tag.name)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
    }

    // MARK: - Source Field

    private var sourceField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source")
                .font(.headline)

            TextField("Source (optional, e.g. \"user\", \"claude\")", text: $source)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Actions

    private func addTag() {
        let tag = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !selectedTags.contains(tag) else { return }
        selectedTags.append(tag)
        tagInput = ""
    }

    private func createMemory() {
        let finalCategory = useCustomCategory ? customCategory : category
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }

        _ = viewModel.createMemory(
            content: trimmedContent,
            category: finalCategory.isEmpty ? "general" : finalCategory,
            tags: selectedTags,
            source: source.isEmpty ? nil : source,
            metadata: nil
        )
        dismiss()
    }
}
