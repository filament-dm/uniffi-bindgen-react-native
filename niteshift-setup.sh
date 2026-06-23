#!/usr/bin/env bash
#
# niteshift-setup.sh
#
# Provisions a development environment for `uniffi-bindgen-react-native`.
#
# This follows the "Local development" contributor guide
# (docs/src/contributing/local-development.md) and the CI workflow
# (.github/workflows/ci.yml), targeting a Linux (Debian/Ubuntu) sandbox.
#
# It installs:
#   - C++ build tooling (cmake, ninja, clang-format, a C++ compiler)
#   - the Rust toolchain (via rustup) plus the wasm32 target
#   - wasm-bindgen-cli (for the WASM bindings flavor)
#   - yarn + JS dependencies, and builds the @ubjs/core TypeScript package
#   - Hermes + the C++ test-harness (via `cargo xtask bootstrap`)
#
# The script is idempotent: re-running it skips work that is already done.
# Mobile-only tooling (Android NDK / cargo-ndk, Xcode/iOS targets) is left
# out, since it cannot be exercised in a headless Linux sandbox.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# Pin to match .github/workflows/ci.yml so generated WASM bindings match CI.
WASM_BINDGEN_VERSION="0.2.100"
# Hermes branch used by the JSI integration tests in CI.
HERMES_BRANCH="rn/0.77-stable"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. System packages for building C++ (Hermes + the test harness).
# ---------------------------------------------------------------------------
log "Installing C++ build tooling via apt"
export DEBIAN_FRONTEND=noninteractive
SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
$SUDO apt-get update -y
$SUDO apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    clang-format \
    git \
    python3 \
    curl \
    pkg-config \
    libssl-dev \
    libicu-dev

# ---------------------------------------------------------------------------
# 2. Rust toolchain.
# ---------------------------------------------------------------------------
if ! command -v rustup >/dev/null 2>&1; then
    log "Installing Rust toolchain via rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
fi
# Make cargo/rustc available for the rest of this script.
# shellcheck disable=SC1091
. "$HOME/.cargo/env"

log "Rust toolchain: $(rustc --version) / $(cargo --version)"

log "Adding wasm32-unknown-unknown target"
rustup target add wasm32-unknown-unknown

# ---------------------------------------------------------------------------
# 3. wasm-bindgen-cli (for the WASM bindings flavor).
# ---------------------------------------------------------------------------
if ! command -v wasm-bindgen >/dev/null 2>&1 \
    || [ "$(wasm-bindgen --version | awk '{print $2}')" != "$WASM_BINDGEN_VERSION" ]; then
    log "Installing wasm-bindgen-cli v${WASM_BINDGEN_VERSION}"
    cargo install wasm-bindgen-cli --version "$WASM_BINDGEN_VERSION" --locked
else
    log "wasm-bindgen-cli v${WASM_BINDGEN_VERSION} already installed"
fi

# ---------------------------------------------------------------------------
# 4. Node tooling: yarn + JS dependencies + TypeScript build.
# ---------------------------------------------------------------------------
if ! command -v yarn >/dev/null 2>&1; then
    log "Enabling yarn via corepack"
    corepack enable || npm install -g yarn
fi
log "Node: $(node --version), yarn: $(yarn --version)"

# `cargo xtask bootstrap yarn` runs `yarn --frozen-lockfile` at the repo root.
log "Installing JS dependencies (cargo xtask bootstrap yarn)"
cargo xtask bootstrap yarn

# Build the @ubjs/core runtime package consumed by generated bindings.
log "Building the TypeScript runtime (@ubjs/core)"
(cd typescript && npm install && npm run build)

# ---------------------------------------------------------------------------
# 5. Hermes + C++ test harness.
#
# This clones facebook/hermes and builds it with cmake/ninja, then builds the
# cpp/test-harness. The first run is slow (Hermes is compiled from source);
# subsequent runs are skipped via the xtask marker files.
# ---------------------------------------------------------------------------
log "Bootstrapping Hermes (branch ${HERMES_BRANCH}) and the test harness"
# xtask uses directory existence as its "already built" marker. A previously
# interrupted run can leave a `build/hermes` directory without a compiled
# `bin/hermes` binary, which would then be wrongly skipped. Detect that partial
# state and force a clean rebuild so reruns self-heal.
HERMES_FORCE=""
if [ -d build/hermes ] && [ ! -x build/hermes/bin/hermes ]; then
    log "Found an incomplete Hermes build; forcing a clean rebuild"
    HERMES_FORCE="--force"
fi
cargo xtask bootstrap $HERMES_FORCE hermes --branch "$HERMES_BRANCH"
cargo xtask bootstrap

# ---------------------------------------------------------------------------
# 6. Warm the build cache so the workspace is ready to use.
# ---------------------------------------------------------------------------
log "Building the Rust workspace"
cargo build

log "Setup complete. Try: cargo test -p uniffi-fixture-arithmetic"
