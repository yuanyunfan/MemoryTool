#!/usr/bin/env bash
set -euo pipefail

BOLD="\033[1m"; GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; NC="\033[0m"
log()   { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

echo -e "${BOLD}MemoryTool — Environment Init${NC}"
echo "=================================="

# 1. Check Swift version
if command -v swift &>/dev/null; then
    SWIFT_VERSION=$(swift --version 2>&1 | head -1)
    log "Swift: $SWIFT_VERSION"
else
    error "Swift not found. Install Xcode from App Store."
fi

# 2. Check Xcode
if command -v xcodebuild &>/dev/null; then
    XCODE_VERSION=$(xcodebuild -version 2>&1 | head -1)
    log "Xcode: $XCODE_VERSION"
else
    error "Xcode not found. Install from App Store."
fi

# 3. Check macOS version
MACOS_VERSION=$(sw_vers -productVersion)
log "macOS: $MACOS_VERSION"

# 4. Check Package.swift exists
if [ -f Package.swift ]; then
    log "Package.swift found"
else
    warn "Package.swift not found — run phase-0 scaffolding first"
fi

# 5. Resolve dependencies
if [ -f Package.swift ]; then
    echo ""
    echo -e "${BOLD}Resolving Swift Package dependencies...${NC}"
    swift package resolve && log "Dependencies resolved" || warn "Dependency resolution failed"
fi

# 6. Build check
if [ -f Package.swift ]; then
    echo ""
    echo -e "${BOLD}Building project...${NC}"
    swift build 2>&1 && log "Build succeeded" || warn "Build failed — check errors above"
fi

# 7. Check required files
echo ""
echo -e "${BOLD}Checking harness files...${NC}"
for f in CLAUDE.md claude-progress.txt feature_list.json CHANGELOG.md; do
    [ -f "$f" ] && log "$f" || warn "$f missing"
done

echo ""
echo -e "${GREEN}${BOLD}Ready!${NC}"
echo "Useful commands:"
echo "  swift build              → Build all targets"
echo "  swift test               → Run tests"
echo "  swift run MemoryMCP      → Run MCP server"
echo "  open MemoryTool.xcodeproj → Open in Xcode"
