#!/usr/bin/env bash
# Sets up stuckwithfood on a fresh Mac: Node/pnpm, dependencies, .env.local,
# Xcode command-line tools, and the macOS permissions the automation needs.
# Safe to re-run — every step skips if it's already done.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This app only runs on macOS — it drives iPhone Mirroring, which is Mac-only."
    exit 1
fi

bold "Setting up stuckwithfood"

# --- Node.js -----------------------------------------------------------
step "Checking Node.js"
REQUIRED_NODE="22"
if command -v nvm >/dev/null 2>&1 || [ -s "$HOME/.nvm/nvm.sh" ]; then
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1091
    source "$NVM_DIR/nvm.sh"
    nvm install >/dev/null
    nvm use >/dev/null
    ok "Node $(node -v) active via nvm"
elif command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
    if [ "$NODE_MAJOR" -lt "$REQUIRED_NODE" ]; then
        echo "Node $(node -v) is installed, but this app needs Node $REQUIRED_NODE or newer."
        echo "Install nvm (https://github.com/nvm-sh/nvm) and re-run this script, or upgrade Node yourself."
        exit 1
    fi
    ok "Node $(node -v)"
else
    echo "Node.js isn't installed."
    echo "Install it from https://nodejs.org (or via nvm: https://github.com/nvm-sh/nvm) and re-run this script."
    exit 1
fi

# --- pnpm ----------------------------------------------------------------
step "Enabling pnpm"
corepack enable >/dev/null 2>&1 || true
corepack prepare pnpm@10.15.1 --activate >/dev/null
ok "pnpm $(pnpm --version)"

# --- Dependencies ----------------------------------------------------------
step "Installing project dependencies"
pnpm install
ok "Dependencies installed"

# --- .env.local --------------------------------------------------------
step "Configuring API keys"
ENV_FILE=".env.local"
touch "$ENV_FILE"

get_existing() {
    grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true
}

set_env_var() {
    local key="$1" value="$2"
    if grep -q "^$key=" "$ENV_FILE" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        awk -v k="$key" -v v="$value" -F= 'BEGIN{OFS="="} $1==k{$0=k"="v} {print}' "$ENV_FILE" > "$tmp"
        mv "$tmp" "$ENV_FILE"
    else
        echo "$key=$value" >> "$ENV_FILE"
    fi
}

GOOGLE_KEY="$(get_existing GOOGLE_MAPS_PLACES_API_KEY)"
if [ -z "$GOOGLE_KEY" ]; then
    echo "  Needs a Google Maps API key with Places API (New) enabled."
    read -r -p "  Paste your GOOGLE_MAPS_PLACES_API_KEY: " GOOGLE_KEY
    if [ -z "$GOOGLE_KEY" ]; then
        echo "A Google Maps API key is required — re-run this script once you have one."
        exit 1
    fi
    set_env_var GOOGLE_MAPS_PLACES_API_KEY "$GOOGLE_KEY"
    ok "Saved GOOGLE_MAPS_PLACES_API_KEY"
else
    ok "GOOGLE_MAPS_PLACES_API_KEY already set"
fi

if command -v codex >/dev/null 2>&1; then
    ok "Codex CLI found — photo labeling will use it (run 'codex login' if you haven't)"
else
    OPENROUTER_KEY="$(get_existing OPENROUTER_API_KEY)"
    if [ -z "$OPENROUTER_KEY" ]; then
        echo "  No Codex CLI found. Photo labeling needs either Codex CLI or an OpenRouter API key."
        read -r -p "  Paste your OPENROUTER_API_KEY (or leave blank to set this up later): " OPENROUTER_KEY
        if [ -n "$OPENROUTER_KEY" ]; then
            set_env_var OPENROUTER_API_KEY "$OPENROUTER_KEY"
            ok "Saved OPENROUTER_API_KEY"
        else
            warn "No labeling provider configured yet — add OPENROUTER_API_KEY to .env.local or install Codex CLI before labeling photos"
        fi
    else
        ok "OPENROUTER_API_KEY already set"
    fi
fi

# --- Xcode command-line tools -------------------------------------------
step "Checking Xcode command-line tools"
if xcode-select -p >/dev/null 2>&1; then
    ok "Already installed"
else
    warn "Not installed — a macOS installer window will open"
    xcode-select --install
    echo "  Finish the installer, then re-run this script to continue."
    exit 0
fi

# --- macOS permissions ---------------------------------------------------
step "macOS permissions"
echo "  The automation needs two permissions granted to the terminal app you're running this in:"
echo "    - Accessibility"
echo "    - Screen & System Audio Recording"
echo "  Opening System Settings for both — enable your terminal app in each, then restart the terminal."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null || true

step "Done"
echo "  1. Grant the two permissions above if you haven't, then restart your terminal app."
echo "  2. Make sure iPhone Mirroring is set up with the iPhone you'll rank on, and Beli is installed and signed in there."
echo "  3. Run: pnpm dev"
echo "  4. Open: http://localhost:3000"
