# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

## [0.2.0] - 2026-04-08

### Added
- **Semantic search**: multilingual-e5-small embedding (384-dim), hybrid FTS5 + vector search
- **Deduplication**: SHA-256 content hash for exact dedup, cosine similarity > 0.85 for near-dup auto-merge
- **Ranking weights**: 4-factor scoring (keyword 0.35 + semantic 0.35 + recency 0.15 + frequency 0.15)
- **Access tracking**: access_count + last_accessed_at columns, auto-updated on recall
- **Embedding backfill**: MCP server auto-backfills embeddings for existing memories on startup
- **Claude Code Hook integration**: SessionStart hook auto-injects project-related memories into session context (`~/.claude/hooks/memory-session-start.sh`)
- **Session summary workflow**: CLAUDE.md instructions for automatic session summary persistence with source-based project filtering

## [0.1.0] - 2026-04-03

### Added
- Project initialized
- AI Native Harness configuration (CLAUDE.md + progress tracking + Hooks + commands + quality gates)
- Product design: native macOS memory management app with embedded MCP server
- Technology decisions: Swift 6.3 + SwiftUI + GRDB.swift + modelcontextprotocol/swift-sdk
