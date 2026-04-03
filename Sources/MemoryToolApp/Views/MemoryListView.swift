import SwiftUI
import MemoryCore

/// Middle column: searchable list of memories.
struct MemoryListView: View {
    @Bindable var viewModel: MemoryViewModel

    var body: some View {
        Group {
            if viewModel.memories.isEmpty && !viewModel.isLoading {
                emptyState
            } else {
                memoryList
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search memories…")
        .onChange(of: viewModel.searchText) {
            viewModel.searchDebounced()
        }
        .navigationTitle(navigationTitle)
    }

    // MARK: - Subviews

    private var memoryList: some View {
        List(viewModel.memories, selection: $viewModel.selectedMemoryId) { memory in
            MemoryRowView(memory: memory)
                .tag(memory.id)
                .contextMenu {
                    Button("Copy Content") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(memory.content, forType: .string)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        viewModel.deleteMemory(id: memory.id)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Delete", role: .destructive) {
                        viewModel.deleteMemory(id: memory.id)
                    }
                }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Memories", systemImage: "brain")
        } description: {
            if viewModel.searchText.isEmpty {
                Text("No memories yet. Create one or let AI remember for you.")
            } else {
                Text("No memories match \"\(viewModel.searchText)\".")
            }
        }
    }

    private var navigationTitle: String {
        if let tag = viewModel.selectedTag {
            return "#\(tag)"
        }
        return viewModel.selectedCategory ?? "All Memories"
    }
}

// MARK: - Row View

struct MemoryRowView: View {
    let memory: Memory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(memory.content)
                .lineLimit(2)
                .font(.body)

            HStack {
                Text(memory.category)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())

                Spacer()

                Text(DateFormatters.relativeString(from: memory.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
