#!/usr/bin/env bash
# MemoryTool — Quick Install
# Usage: ./install.sh
#
# Builds the MemoryMCP binary, copies it to a stable location,
# and configures Claude Code to use it as an MCP server.

set -euo pipefail

INSTALL_DIR="$HOME/.memorytool/bin"
BINARY_NAME="MemoryMCP"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
SERVER_KEY="memory-tool"

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    NC='\033[0m'
else
    GREEN='' YELLOW='' RED='' NC=''
fi

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; }

# ---- Step 1: Build release binary ----
echo "Building $BINARY_NAME (release)..."
if ! swift build -c release --product "$BINARY_NAME" 2>&1; then
    error "Build failed. Make sure you're in the MemoryTool project root."
    exit 1
fi
info "Build succeeded."

# ---- Step 2: Install binary (symlink to avoid macOS code signing issues with cp) ----
mkdir -p "$INSTALL_DIR"
BUILT_BINARY="$(cd "$(dirname "$0")" && pwd)/.build/release/$BINARY_NAME"
rm -f "$INSTALL_DIR/$BINARY_NAME"
ln -s "$BUILT_BINARY" "$INSTALL_DIR/$BINARY_NAME"
info "Installed $BINARY_NAME → $INSTALL_DIR/$BINARY_NAME (symlink)"

# ---- Step 3: Ensure data directory ----
mkdir -p "$HOME/.memorytool"
info "Data directory: $HOME/.memorytool/"

# ---- Step 4: Configure Claude Code ----
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"

configure_claude() {
    # We use python3 (pre-installed on macOS) for safe JSON manipulation
    python3 - "$CLAUDE_SETTINGS" "$SERVER_KEY" "$BINARY_PATH" <<'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
server_key    = sys.argv[2]
binary_path   = sys.argv[3]

# Read existing settings or start fresh
if os.path.isfile(settings_path):
    with open(settings_path, "r") as f:
        try:
            settings = json.load(f)
            if not isinstance(settings, dict):
                settings = {}
        except json.JSONDecodeError:
            settings = {}
else:
    # Create parent directory if needed
    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    settings = {}

# Merge MCP server entry
mcp_servers = settings.setdefault("mcpServers", {})
mcp_servers[server_key] = {
    "command": binary_path,
    "args": [],
    "env": {}
}

# Write back
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"Configured '{server_key}' in {settings_path}")
PYEOF
}

if command -v python3 &>/dev/null; then
    if configure_claude; then
        info "Claude Code configured automatically."
    else
        warn "Auto-configuration failed. Please add the config manually (see below)."
    fi
else
    warn "python3 not found — cannot auto-configure Claude Code."
fi

# ---- Step 5: Print manual config ----
echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Manual Configuration (if needed)"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Add this to your Claude Code settings ($CLAUDE_SETTINGS):"
echo ""
echo "  \"mcpServers\": {"
echo "    \"$SERVER_KEY\": {"
echo "      \"command\": \"$BINARY_PATH\","
echo "      \"args\": [],"
echo "      \"env\": {}"
echo "    }"
echo "  }"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo ""
info "Installation complete! Restart Claude Code to use MemoryTool."
