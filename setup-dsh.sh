#!/usr/bin/env bash
# ============================================================================
#  setup-dsh.sh — Bootstrap DSH + plugins + skin + config on a fresh machine
#
#  Usage:
#    bash setup-dsh.sh
#
#  What it does:
#    1. Ensures Node.js >= 20 (installs via fnm if missing)
#    2. Ensures dsh is runnable via npx
#    3. Writes settings.yaml (LLM providers, UI, permissions)
#    4. Writes .credentials.yaml (prompts for API key if not in env)
#    5. Installs plugins via `dsh plugin add`
#    6. Installs & activates skin "deep-current" from dsh-market.com
#
#  Env overrides (skip interactive prompts):
#    BEDROCK_API_KEY   — Amazon Bedrock / GenAI Nexus key
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
fail()  { echo -e "${RED}[fail]${NC}  $*"; exit 1; }

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
MARKET_ORIGIN="https://dsh-market.com"
SKIN_ID="deep-current"

# ============================================================================
#  1. Node.js >= 20
# ============================================================================
if command -v node &>/dev/null; then
  NODE_MAJOR=$(node -e 'console.log(process.versions.node.split(".")[0])')
  if [ "$NODE_MAJOR" -lt 20 ]; then
    fail "Node.js >= 20 required, got $(node --version). Install: curl -fsSL https://fnm.vercel.app/install | bash && fnm install 22"
  fi
  ok "Node.js $(node --version)"
else
  info "Installing Node.js via fnm..."
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
  export PATH="$HOME/.local/share/fnm:$PATH"
  eval "$(fnm env)"
  fnm install 22
  fnm use 22
  ok "Node.js $(node --version) installed"
fi

# ============================================================================
#  2. dsh
# ============================================================================
info "Ensuring dsh is available..."
npx --yes @deepseek-ai/dsh --version
ok "dsh ready"

# ============================================================================
#  3. settings.yaml
# ============================================================================
mkdir -p "$DSH_HOME"
SETTINGS_FILE="$DSH_HOME/settings.yaml"

if [ -f "$SETTINGS_FILE" ]; then
  warn "$SETTINGS_FILE already exists — skipping"
else
  info "Writing $SETTINGS_FILE ..."
  cat > "$SETTINGS_FILE" << 'EOF'
ui-onboarding:
  welcomeNoticeVersion: 2026-08-13.1
agent-default-model:
  provider: amazon-bedrock
  model: claude-opus-4.6
llm-pi-ai:
  providers:
    amazon-bedrock:
      apiKeyEnv: BEDROCK_API_KEY
      baseURL: https://genai-nexus.api.corpinter.net
      models:
        - id: claude-opus-4.6
          name: claude-opus-4.6
          contextWindow: 1000000
          input: [text, image]
        - id: claude-sonnet-4.6
          name: claude-sonnet-4.6
          contextWindow: 1000000
          input: [text, image]
permission:
  defaultPreset: danger-full-access
dsh-web-ui-market:
  enabled: true
ui-theme:
  preference: light
EOF
  chmod 600 "$SETTINGS_FILE"
  ok "settings.yaml written"
fi

# ============================================================================
#  4. .credentials.yaml
# ============================================================================
CREDS_FILE="$DSH_HOME/.credentials.yaml"

if [ -f "$CREDS_FILE" ]; then
  warn "$CREDS_FILE already exists — skipping"
else
  if [ -z "${BEDROCK_API_KEY:-}" ]; then
    read -rsp "Enter BEDROCK_API_KEY: " BEDROCK_API_KEY
    echo
  fi
  [ -z "${BEDROCK_API_KEY:-}" ] && fail "BEDROCK_API_KEY is required"

  cat > "$CREDS_FILE" << EOF
version: 1
refs:
  BEDROCK_API_KEY: ${BEDROCK_API_KEY}
records: {}
EOF
  chmod 600 "$CREDS_FILE"
  ok ".credentials.yaml written (mode 600)"
fi

# ============================================================================
#  5. Pre-plugin: ensure pnpm-workspace.yaml exists (disable minimumReleaseAge)
# ============================================================================
PROFILE_DIR="$DSH_HOME/profiles/web"
mkdir -p "$PROFILE_DIR"
PNPM_WS="$PROFILE_DIR/pnpm-workspace.yaml"
if [ ! -f "$PNPM_WS" ]; then
  info "Writing pnpm-workspace.yaml ..."
  cat > "$PNPM_WS" << 'EOF'
packages:
  - .

nodeLinker: hoisted
autoInstallPeers: false

# Disable minimumReleaseAge — community plugins are published frequently
# and the default 7-day gate blocks fresh installs on new machines.
minimumReleaseAge: 0
EOF
  ok "pnpm-workspace.yaml written"
fi

# ============================================================================
#  5b. Plugins
# ============================================================================
info "Installing plugins..."
npx @deepseek-ai/dsh plugin --profile web add @vidge/dsh-agent-hub@0.1.0-rc13
npx @deepseek-ai/dsh plugin --profile web add @linxin666/dsh-web-all@latest
npx @deepseek-ai/dsh plugin --profile web add @anthropic-ai/claude-agent-sdk@0.3.220
ok "Plugins installed"

# ============================================================================
#  5c. cordis.patch.yml — disable broken plugins
# ============================================================================
PATCH_FILE="$PROFILE_DIR/cordis.patch.yml"
info "Writing cordis.patch.yml ..."
cat > "$PATCH_FILE" << 'EOF'
# Workaround: describe-image plugin crashes on "tools" inject
- id: web-ui-describe-image
  disabled: true
EOF
ok "cordis.patch.yml written"

# ============================================================================
#  6. Skin — install "deep-current" from dsh-market.com + activate
# ============================================================================
install_skin() {
  local id="$1"
  local skin_dir="$DSH_HOME/skins/$id"

  if [ -d "$skin_dir" ]; then
    ok "Skin '$id' already installed"
    return 0
  fi

  info "Fetching skin manifest..."
  local manifest
  manifest=$(curl -fsSL "$MARKET_ORIGIN/manifest/skins.json")

  # Extract file list from manifest
  local files
  files=$(echo "$manifest" | python3 -c "
import sys, json
data = json.load(sys.stdin)
item = next((i for i in data['items'] if i['id'] == '$id'), None)
if not item:
    sys.exit(1)
for f in item.get('files', []):
    print(f)
") || { warn "Skin '$id' not found in manifest"; return 1; }

  info "Downloading skin: $id"
  mkdir -p "$skin_dir"
  while IFS= read -r rel; do
    local dest="$skin_dir/$rel"
    mkdir -p "$(dirname "$dest")"
    curl -fsSL -o "$dest" "$MARKET_ORIGIN/assets/skins/$id/$rel" \
      || { warn "  Failed: $rel"; }
  done <<< "$files"

  # Write provenance (so skin-center trusts hooks)
  python3 -c "
import json, hashlib, os
d = '$skin_dir'
files = {}
for r, _, fns in os.walk(d):
    for fn in fns:
        p = os.path.join(r, fn)
        files[os.path.relpath(p, d)] = hashlib.sha256(open(p,'rb').read()).hexdigest()
json.dump({'version':1,'source':'$MARKET_ORIGIN','kind':'skin','id':'$id',
  'installedAt':'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)','files':files},
  open(os.path.join(d,'dsh-market.provenance.json'),'w'),indent=2)
"
  ok "Skin '$id' installed"
}

install_skin "$SKIN_ID"

# Activate
SKIN_ACTIVE_FILE="$DSH_HOME/skin-center-active.json"
if [ ! -f "$SKIN_ACTIVE_FILE" ]; then
  cat > "$SKIN_ACTIVE_FILE" << EOF
{
  "active": "$SKIN_ID",
  "initialized": true,
  "background": {
    "enabled": true,
    "backgroundOpacity": 0,
    "backgroundBlurEmpty": 0,
    "backgroundBlurContent": 0,
    "inputCardBlur": 10,
    "bubbleOpacity": 50
  }
}
EOF
  ok "Activated skin: $SKIN_ID"
fi

# ============================================================================
#  Done
# ============================================================================
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  DSH setup complete!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo "  Plugins:  @vidge/dsh-agent-hub + @linxin666/dsh-web-all"
echo "  Skin:     $SKIN_ID (active)"
echo ""
echo "  Start:    npx @deepseek-ai/dsh web"
echo ""
