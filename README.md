# MemoryTool

<p align="center">
  <img src="Sources/MemoryToolApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="MemoryTool Icon">
</p>

<p align="center">
  A native macOS app that provides <strong>persistent, cross-session memory</strong> for AI assistants.<br>
  Tell Claude something once — every future session knows it.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/swift-6.0-orange" alt="Swift">
  <img src="https://img.shields.io/badge/MCP-stdio-green" alt="MCP">
  <img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="License">
</p>

---

## What It Does

MemoryTool combines a **SwiftUI GUI** for human management with an embedded **MCP server** that AI tools (Claude Code, Claude Desktop) use to store and retrieve memories via stdio transport.

```
┌─────────────────────────────────────────────┐
│              MemoryTool.app                  │
│                                              │
│  ┌──────────────┐    ┌───────────────────┐   │
│  │   SwiftUI    │    │   MCP Server      │   │
│  │   GUI        │    │   (stdio)         │   │
│  │  CRUD +      │    │  remember/recall  │   │
│  │  Search      │    │  forget/update    │   │
│  └──────┬───────┘    └──────┬────────────┘   │
│         └────────┬──────────┘                │
│          ┌───────┴───────┐                   │
│          │  SQLite + FTS5│                   │
│          │  (WAL mode)   │                   │
│          └───────────────┘                   │
└─────────────────────────────────────────────┘
      ↑                          ↑
    User                    Claude Code
```

## Features

- **6 MCP Tools**: `remember`, `recall`, `forget`, `update_memory`, `list_categories`, `get_memory`
- **Full-Text Search**: SQLite FTS5 with trigram tokenizer — supports Chinese, English, Japanese, Korean, and any language
- **Native macOS GUI**: Three-column NavigationSplitView — categories, memory list, detail editor
- **Auto-Refresh**: GUI automatically detects external database changes from MCP server (2s polling)
- **Multi-Process Safe**: GUI and MCP server share one SQLite file via WAL mode
- **Tags & Categories**: Flexible organization with many-to-many tag relationships
- **Import/Export**: JSON and Markdown export for backup and portability
- **One-Click Install**: `./install.sh` builds, installs, and configures Claude Code automatically

## Requirements

- **macOS 15.0+** (Sequoia)
- **Xcode 16+** / Swift 6.0+
- **Claude Code** (for MCP integration)

## Quick Start

### Option 1: One-Click Install

```bash
git clone https://github.com/yuanyunfan/MemoryTool.git
cd MemoryTool
./install.sh
```

This builds the MCP server, symlinks it to `~/.memorytool/bin/`, and configures Claude Code automatically.

### Option 2: Manual Setup

1. **Build**:
   ```bash
   swift build --product MemoryMCP
   ```

2. **Install binary**:
   ```bash
   mkdir -p ~/.memorytool/bin
   ln -sf "$(pwd)/.build/debug/MemoryMCP" ~/.memorytool/bin/MemoryMCP
   ```

3. **Configure Claude Code** — add to `~/.claude.json` under `mcpServers`:
   ```json
   {
     "memory-tool": {
       "type": "stdio",
       "command": "/Users/YOU/.memorytool/bin/MemoryMCP",
       "args": [],
       "env": {}
     }
   }
   ```

4. **Restart Claude Code** — verify with `/mcp`:
   ```
   memory-tool · ✓ connected
   ```

### Run the GUI App

```bash
./run-app.sh
```

This builds the app and launches it as a proper `.app` bundle (avoids keyboard events leaking to the terminal).

## Tech Stack

| Layer | Choice |
|-------|--------|
| Language | Swift 6.0+ |
| GUI | SwiftUI (macOS 15+) |
| MCP SDK | [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) 0.12.0 |
| Database | SQLite via [GRDB.swift](https://github.com/groue/GRDB.swift) 7.x |
| Search | FTS5 (trigram tokenizer) |
| Transport | stdio |
| Tests | Swift Testing — 59 tests |

## Project Structure

```
MemoryTool/
├── Package.swift                # SPM manifest (3 targets)
├── Sources/
│   ├── MemoryCore/              # Shared library
│   │   ├── Models/              # Memory, Tag, MemoryTag
│   │   ├── Database/            # GRDB setup, migrations, FTS5
│   │   └── Services/            # MemoryService, DataExporter, MCPConfigInstaller
│   ├── MemoryToolApp/           # SwiftUI Mac app
│   │   ├── Views/               # ContentView, Sidebar, List, Detail, NewMemory
│   │   ├── ViewModels/          # MemoryViewModel (@Observable)
│   │   └── Assets.xcassets/     # App icon
│   └── MemoryMCP/               # MCP server CLI
│       ├── main.swift           # stdio transport entry point
│       └── Tools/               # ToolHandler + ToolDefinitions
├── Tests/                       # 59 tests (MemoryCoreTests + MemoryMCPTests)
├── install.sh                   # One-click install + Claude Code config
├── run-app.sh                   # Build + launch as .app bundle
└── init.sh                      # Dev environment check
```

## MCP Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `remember` | Store a new memory | `content` (required), `category`, `tags`, `source`, `metadata` |
| `recall` | Full-text search memories | `query` (required), `category`, `tags`, `limit` |
| `forget` | Delete a memory by ID | `memory_id` (required) |
| `update_memory` | Partially update a memory | `memory_id` (required), `content`, `category`, `tags` |
| `list_categories` | List categories with counts | — |
| `get_memory` | Retrieve a specific memory | `memory_id` (required) |

## How It Works

1. **You tell Claude something** — e.g., "I'm a data engineer working with PySpark"
2. **Claude calls `remember`** — stores it in SQLite with category `user-preference`
3. **In a new session**, Claude calls `recall("data engineer")` — retrieves the memory
4. **You manage memories** via the SwiftUI app — search, edit, tag, delete, export

The GUI app and MCP server share the same SQLite database (`~/.memorytool/memory.db`) via WAL mode, so changes from either side are immediately visible.

## Configuration

| Item | Location |
|------|----------|
| Database | `~/.memorytool/memory.db` |
| MCP Binary | `~/.memorytool/bin/MemoryMCP` |
| Claude Code config | `~/.claude.json` → `mcpServers.memory-tool` |
| Custom DB path | Set env `MEMORY_TOOL_DB_PATH` |

## Development

```bash
# Check environment
./init.sh

# Build all targets
swift build

# Run tests (59 tests)
swift test

# Run MCP server directly
swift run MemoryMCP

# Launch GUI app
./run-app.sh
```

## Known Issues

- **macOS binary copy issue**: `cp` of release binaries may fail silently due to macOS code signing. The install script uses `ln -s` (symlink) to avoid this.
- **App Store**: Not currently distributed via App Store (MCP companion binary requires unsandboxed execution).

## License

MIT
