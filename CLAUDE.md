# CLAUDE.md

## Project Overview

MemoryTool is a native macOS app that provides persistent, cross-session memory for AI assistants (primarily Claude Code). It combines a SwiftUI GUI for human CRUD management with an embedded MCP (Model Context Protocol) server that AI tools use to store/retrieve memories via stdio transport. The core value: tell Claude something once, and every future session knows it.

## Tech Stack

- **Language**: Swift 6.3
- **GUI**: SwiftUI (macOS 15.0+)
- **IDE**: Xcode 26.4
- **Package Manager**: Swift Package Manager
- **MCP SDK**: modelcontextprotocol/swift-sdk 0.12.0
- **Database**: SQLite (via GRDB.swift 7.x) with FTS5 full-text search
- **Transport**: stdio (MCP standard for local tools)
- **Testing**: Swift Testing + XCTest
- **Min Deployment**: macOS 15.0 (Sequoia)

## Architecture

```
MemoryTool.app
├── MemoryToolApp (SwiftUI GUI target)
│   └── Views, ViewModels
├── MemoryMCP (CLI executable target, MCP server)
│   └── Reads/writes same SQLite via stdio
└── MemoryCore (shared library)
    ├── Models (Memory, Tag, etc.)
    ├── Database (GRDB DAOs, migrations)
    └── Services (MemoryService, SearchService)
```

Key constraint: GUI process and MCP server process share one SQLite file (WAL mode). Never use print() in MCP target — stdout is the MCP communication channel.

## Commands

```bash
swift build                    # Build all targets
swift build -c release         # Release build
swift test                     # Run tests
swift run MemoryMCP            # Run MCP server (stdio mode)
open MemoryTool.xcodeproj      # Open in Xcode (if using .xcodeproj)
./init.sh                      # Environment init & dependency check
```

## Session Workflow (MANDATORY)

> **IMPORTANT**: The following steps are mandatory. Execute them every session, no exceptions.

### Session start — execute immediately:
1. **Read `claude-progress.txt`** — understand last session's progress, current state, known issues
2. **Read `feature_list.json`** — confirm next `"passes": false` feature
3. **Brief the user**: "Last progress: XXX, this session plan: YYY"

### After completing each feature:
4. **Update `feature_list.json`** — set passes to true
5. **Update phase status** — if all features in phase pass, set status to "done"
6. **Update summary** — recalculate done/remaining/progress_pct

### Before session ends — must execute:
7. **Update `claude-progress.txt`** — record completions, next steps, issues encountered
8. **Update `CHANGELOG.md`** — if significant functionality completed

## Testing

- **Framework**: Swift Testing (primary) + XCTest (compatibility)
- **Location**: `Tests/MemoryCoreTests/`, `Tests/MemoryMCPTests/`
- **Naming**: `test_<function>_<scenario>_<expectedResult>`
- **Coverage target**: Core data layer 80%+, MCP tools 90%+
- **Run**: `swift test` or Xcode Test Navigator

## Project Structure

```
MemoryTool/
├── Package.swift                    # SPM manifest (3 targets)
├── Sources/
│   ├── MemoryCore/                  # Shared library
│   │   ├── Models/                  # Memory, Tag, Settings models
│   │   ├── Database/                # GRDB setup, migrations, DAOs
│   │   └── Services/                # Business logic
│   ├── MemoryToolApp/               # SwiftUI Mac app
│   │   ├── App.swift                # Entry point
│   │   ├── Views/                   # SwiftUI views
│   │   └── ViewModels/              # ObservableObject VMs
│   └── MemoryMCP/                   # MCP server CLI
│       ├── main.swift               # Entry, stdio transport setup
│       └── Tools/                   # MCP tool implementations
├── Tests/
│   ├── MemoryCoreTests/             # Core logic tests
│   └── MemoryMCPTests/              # MCP tool tests
├── Resources/                       # Assets, default config
├── CLAUDE.md                        # This file
├── claude-progress.txt              # Session progress tracking
├── feature_list.json                # Feature tracking
├── CHANGELOG.md                     # Version history
└── init.sh                          # Environment setup
```

## Architecture Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| GUI framework | SwiftUI | Native macOS, best system integration |
| MCP SDK | Official swift-sdk | Production-grade, maintained by Anthropic |
| Database | SQLite via GRDB.swift | FTS5 built-in, WAL for multi-process, single-file backup |
| MCP transport | stdio | Standard for Claude Code, zero-config, best performance |
| App + MCP split | Companion binary in bundle | MCP runs as separate process, shares SQLite |
| Search V1 | FTS5 keyword search | Covers 80% needs; vector search deferred to V2 |
| Logging in MCP | os_log / stderr only | stdout is MCP channel, print() would corrupt protocol |

## Data Model

```sql
-- Core memory table
CREATE TABLE memory (
    id TEXT PRIMARY KEY,          -- UUID
    content TEXT NOT NULL,        -- Memory content
    category TEXT DEFAULT 'general',
    source TEXT,                  -- Which session/context created it
    created_at TEXT NOT NULL,     -- ISO 8601
    updated_at TEXT NOT NULL,
    metadata TEXT                 -- JSON blob for extensibility
);

-- FTS5 virtual table for full-text search
CREATE VIRTUAL TABLE memory_fts USING fts5(content, category, source, content='memory', content_rowid='rowid');

-- Tags for flexible categorization
CREATE TABLE tag (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL
);

CREATE TABLE memory_tag (
    memory_id TEXT REFERENCES memory(id) ON DELETE CASCADE,
    tag_id INTEGER REFERENCES tag(id) ON DELETE CASCADE,
    PRIMARY KEY (memory_id, tag_id)
);
```

## MCP Tools (Exposed to AI)

| Tool | Purpose | Key Params |
|------|---------|------------|
| `remember` | Store a new memory | content, category?, tags?, metadata? |
| `recall` | Search memories by keyword | query, category?, tags?, limit? |
| `forget` | Delete a memory | memory_id |
| `update_memory` | Modify existing memory | memory_id, content?, category?, tags? |
| `list_categories` | List all categories | — |
| `get_memory` | Get single memory by ID | memory_id |

## Conventions

- **Swift style**: Follow Swift API Design Guidelines
- **Naming**: camelCase for properties/functions, PascalCase for types
- **Error handling**: Use typed throws where possible, never force-unwrap
- **Concurrency**: Swift structured concurrency (async/await, actors)
- **Database**: All DB access through MemoryService (never raw SQL in views)
- **Imports**: Group by Foundation → Third-party → Local modules

## Git Quality Gates

Pre-commit checks (sequential, fail-fast):
1. `swift build` — compilation must succeed
2. `swift test` — all tests must pass

**Never use `--no-verify` to bypass hooks.**

## Retrospective

> Append major lessons learned here. Format: **[Date] Issue**: Root cause -> Fix -> Lesson
