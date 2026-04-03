import SwiftUI
import MemoryCore

/// Sidebar showing category and tag filters.
struct SidebarView: View {
    @Bindable var viewModel: MemoryViewModel

    var body: some View {
        List(selection: Binding<SidebarItem?>(
            get: { currentSelection },
            set: { handleSelection($0) }
        )) {
            Section("Categories") {
                Label("All Memories", systemImage: "tray.2")
                    .badge(viewModel.totalCount)
                    .tag(SidebarItem.allMemories)

                ForEach(viewModel.categories, id: \.self) { category in
                    Label(category, systemImage: iconForCategory(category))
                        .badge(viewModel.countForCategory(category))
                        .tag(SidebarItem.category(category))
                }
            }

            Section("Tags") {
                if viewModel.tags.isEmpty {
                    Text("No tags yet")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(viewModel.tags) { tag in
                        Label(tag.name, systemImage: "tag")
                            .tag(SidebarItem.tag(tag.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MemoryTool")
    }

    // MARK: - Helpers

    private var currentSelection: SidebarItem? {
        if let tag = viewModel.selectedTag {
            return .tag(tag)
        }
        if let category = viewModel.selectedCategory {
            return .category(category)
        }
        return .allMemories
    }

    private func handleSelection(_ item: SidebarItem?) {
        switch item {
        case .allMemories, .none:
            viewModel.selectCategory(nil)
        case .category(let name):
            viewModel.selectCategory(name)
        case .tag(let name):
            viewModel.selectTag(name)
        }
    }

    private func iconForCategory(_ category: String) -> String {
        switch category {
        case "general": "folder"
        case "user-preference": "person"
        case "project": "hammer"
        case "fact": "books.vertical"
        case "code": "chevron.left.forwardslash.chevron.right"
        case "work": "briefcase"
        default: "folder"
        }
    }
}

// MARK: - SidebarItem

enum SidebarItem: Hashable {
    case allMemories
    case category(String)
    case tag(String)
}
