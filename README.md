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
┌───────────────────────────────────────────────────────┐
│                   MemoryTool.app                      │
│                                                       │
│  ┌──────────────┐         ┌───────────────────────┐   │
│  │   SwiftUI    │         │   MCP Server (stdio)  │   │
│  │   GUI        │         │                       │   │
│  │  CRUD +      │         │  remember (dedup)     │   │
│  │  Search      │         │  recall (hybrid)      │   │
│  │  Tag Mgmt    │         │  forget / update      │   │
│  └──────┬───────┘         └──────┬────────────────┘   │
│         └──────────┬─────────────┘                    │
│          ┌─────────┴──────────┐                       │
│          │  SQLite + FTS5     │                       │
│          │  + Embeddings      │                       │
│          │  (WAL mode)        │                       │
│          └────────────────────┘                       │
└───────────────────────────────────────────────────────┘
       ↑                               ↑
     User                         Claude Code
```

## Features

### Core
- **6 MCP Tools**: `remember`, `recall`, `forget`, `update_memory`, `list_categories`, `get_memory`
- **Native macOS GUI**: Three-column NavigationSplitView — categories, memory list, detail editor
- **Multi-Process Safe**: GUI and MCP server share one SQLite file via WAL mode
- **Tags & Categories**: Flexible organization with many-to-many tag relationships
- **Import/Export**: JSON and Markdown export for backup and portability
- **One-Click Install**: `./install.sh` builds, installs, and configures Claude Code automatically

### Search (V1.1)
- **Hybrid Search**: Combines FTS5 keyword matching with semantic vector similarity
- **Semantic Embeddings**: Apple NLContextualEmbedding (system BERT, 768-dim, zero external dependencies)
- **CJK Full-Text**: FTS5 trigram tokenizer — supports Chinese, English, Japanese, Korean
- **Weighted Ranking**: Four-factor scoring — keyword relevance + semantic similarity + recency decay (30-day half-life) + access frequency

### Intelligence (V1.1)
- **Semantic Deduplication**: Cosine similarity > 0.85 detects paraphrases (e.g. "我爱吃火锅" vs "用户爱吃火锅") and merges content automatically
- **Access Tracking**: Records access count and last accessed time for ranking
- **Orphan Cleanup**: Deleting a memory automatically removes unused tags

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
   swift build -c release --product MemoryMCP
   ```

2. **Install binary**:
   ```bash
   mkdir -p ~/.memorytool/bin
   ln -sf "$(pwd)/.build/release/MemoryMCP" ~/.memorytool/bin/MemoryMCP
   ```

3. **Configure Claude Code** — add to `~/.claude/settings.json` under `mcpServers`:
   ```json
   {
     "memory-tool": {
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

This builds the app and launches it as a proper `.app` bundle.

## Tech Stack

| Layer | Choice |
|-------|--------|
| Language | Swift 6.0+ |
| GUI | SwiftUI (macOS 15+) |
| MCP SDK | [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) 0.12.0 |
| Database | SQLite via [GRDB.swift](https://github.com/groue/GRDB.swift) 7.x |
| Keyword Search | FTS5 (trigram tokenizer) |
| Semantic Search | Apple NLContextualEmbedding (768-dim, system BERT) |
| Vector Math | Accelerate (vDSP) |
| Transport | stdio |
| Tests | Swift Testing — 62 tests |

## Project Structure

```
MemoryTool/
├── Package.swift                # SPM manifest (3 targets)
├── Sources/
│   ├── MemoryCore/              # Shared library
│   │   ├── Models/              # Memory, Tag, MemoryTag
│   │   ├── Database/            # GRDB setup, migrations (v1-v3), FTS5
│   │   └── Services/            # MemoryService, EmbeddingService,
│   │                            # DataExporter, MCPConfigInstaller
│   ├── MemoryToolApp/           # SwiftUI Mac app
│   │   ├── Views/               # ContentView, Sidebar, List, Detail, NewMemory
│   │   ├── ViewModels/          # MemoryViewModel (@Observable)
│   │   └── Assets.xcassets/     # App icon
│   └── MemoryMCP/               # MCP server CLI
│       ├── main.swift           # stdio transport entry point
│       └── Tools/               # ToolHandler + ToolDefinitions
├── Tests/                       # 62 tests (MemoryCoreTests + MemoryMCPTests)
├── install.sh                   # One-click install + Claude Code config
├── run-app.sh                   # Build + launch as .app bundle
└── init.sh                      # Dev environment check
```

## MCP Tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `remember` | Store a new memory (with semantic dedup) | `content` (required), `category`, `tags`, `source`, `metadata` |
| `recall` | Hybrid search (keyword + semantic + ranking) | `query` (required), `category`, `tags`, `limit` |
| `forget` | Delete a memory + clean orphan tags | `memory_id` (required) |
| `update_memory` | Partially update a memory | `memory_id` (required), `content`, `category`, `tags` |
| `list_categories` | List categories with counts | — |
| `get_memory` | Retrieve a specific memory | `memory_id` (required) |

## How It Works

### Remember (with dedup)

```
Claude calls remember("用户爱吃火锅")
  → Generate embedding (NLContextualEmbedding)
  → Search existing memories for cosine similarity > 0.85
    → No match → CREATE new memory
    → Match found → MERGE content into existing memory
  → Return memory ID
```

### Recall (hybrid search)

```
Claude calls recall("火锅")
  → FTS5 keyword search → keyword_score
  → Embedding cosine similarity → semantic_score
  → Combine with ranking weights:
      0.35 × keyword + 0.35 × semantic
    + 0.15 × recency_decay (30-day half-life)
    + 0.15 × access_frequency (log-normalized)
  → Return top-K results, record access
```

### Shared Database

The GUI app and MCP server share the same SQLite database (`~/.memorytool/memory.db`) via WAL mode, so changes from either side are immediately visible.

## Database Schema (V3)

```sql
-- Core memory table
CREATE TABLE memory (
    id TEXT PRIMARY KEY,
    content TEXT NOT NULL,
    category TEXT DEFAULT 'general',
    source TEXT,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    metadata TEXT,
    content_hash TEXT,
    access_count INTEGER DEFAULT 0,
    last_accessed_at DATETIME,
    embedding BLOB                -- 768-dim float32 vector
);

-- FTS5 full-text search (trigram tokenizer for CJK)
CREATE VIRTUAL TABLE memory_fts USING fts5(
    content, category, source,
    content='memory', content_rowid='rowid',
    tokenize='trigram'
);

-- Tags (many-to-many)
CREATE TABLE tag (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE);
CREATE TABLE memory_tag (memory_id TEXT, tag_id INTEGER, PRIMARY KEY (memory_id, tag_id));
```

## Configuration

| Item | Location |
|------|----------|
| Database | `~/.memorytool/memory.db` |
| MCP Binary | `~/.memorytool/bin/MemoryMCP` |
| Claude Code config | `~/.claude/settings.json` → `mcpServers.memory-tool` |
| Custom DB path | Set env `MEMORY_TOOL_DB_PATH` |

## Development

```bash
# Check environment
./init.sh

# Build all targets
swift build

# Run tests (62 tests)
swift test

# Run MCP server directly
swift run MemoryMCP

# Launch GUI app
./run-app.sh

# Release build
swift build -c release
```

## Known Issues

- **macOS binary copy issue**: `cp` of release binaries may fail silently due to macOS code signing. The install script uses `ln -s` (symlink) to avoid this.
- **NLContextualEmbedding model download**: The Chinese (Han) embedding model may need to be downloaded by the system on first use. If unavailable, semantic search falls back to keyword-only mode.
- **App Store**: Not currently distributed via App Store (MCP companion binary requires unsandboxed execution).

## License

MIT
