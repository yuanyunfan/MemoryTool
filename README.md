# MemoryTool

A native macOS app that provides **persistent, cross-session memory** for AI assistants. Tell Claude something once — every future session knows it.

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
- **Full-Text Search**: SQLite FTS5 with trigram tokenizer (supports Chinese/English/any language)
- **Native macOS GUI**: Three-column NavigationSplitView — categories, memory list, detail editor
- **Multi-Process Safe**: GUI and MCP server share one SQLite file via WAL mode
- **Tags & Categories**: Flexible organization with many-to-many tag relationships
- **Import/Export**: JSON and Markdown export for backup and portability

## Tech Stack

| Layer | Choice |
|-------|--------|
| Language | Swift 6.3 |
| GUI | SwiftUI (macOS 15+) |
| MCP SDK | [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) 0.12.0 |
| Database | SQLite via [GRDB.swift](https://github.com/groue/GRDB.swift) 7.x |
| Search | FTS5 (trigram tokenizer) |
| Transport | stdio |

## Quick Start

### Install

```bash
git clone git@github-personal:yuanyunfan/MemoryTool.git
cd MemoryTool
./install.sh
```

This builds the MCP server, installs it to `~/.memorytool/bin/`, and configures Claude Code automatically.

### Manual Setup

1. Build:
   ```bash
   swift build -c release --product MemoryMCP
   ```

2. Add to Claude Code (`~/.claude.json` → `mcpServers`):
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

3. Restart Claude Code.

### Run the GUI App

```bash
swift run MemoryToolApp
# or
open .build/debug/MemoryToolApp
```

## Project Structure

```
MemoryTool/
├── Sources/
│   ├── MemoryCore/          # Shared library (models, DB, services)
│   ├── MemoryToolApp/       # SwiftUI Mac app
│   └── MemoryMCP/           # MCP server CLI
├── Tests/
│   ├── MemoryCoreTests/     # 43 tests
│   └── MemoryMCPTests/      # 16 tests (via InMemoryTransport)
├── Package.swift
├── install.sh               # One-click install
└── init.sh                  # Dev environment check
```

## MCP Tools

| Tool | Description |
|------|-------------|
| `remember` | Store a new memory with content, category, tags, and metadata |
| `recall` | Full-text search memories by keyword, with category/tag filters |
| `forget` | Delete a memory by ID |
| `update_memory` | Partially update an existing memory |
| `list_categories` | List all categories with counts |
| `get_memory` | Retrieve a specific memory by ID |

## License

MIT
