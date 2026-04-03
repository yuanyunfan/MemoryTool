import SwiftUI
import MemoryCore

/// Main three-column layout using NavigationSplitView.
struct ContentView: View {
    @State var viewModel: MemoryViewModel
    @State private var showNewMemory = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel)
        } content: {
            MemoryListView(viewModel: viewModel)
        } detail: {
            MemoryDetailView(viewModel: viewModel)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewMemory = true
                } label: {
                    Label("New Memory", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showNewMemory) {
            NewMemoryView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.loadSidebarData()
            viewModel.loadMemories()
        }
        .alert(
            "Error",
            isPresented: Binding<Bool>(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}
