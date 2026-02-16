#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# openwrt-splitdns build script
#
# Baseline:
#   - OpenWrt v24.10.5 (from https://github.com/nicky1605/openwrt, branch openwrt-24.10)
# Feeds:
#   - src-git splitdns https://github.com/nicky1605/openwrt-splitdns-feed.git
# Special:
#   - override feeds/packages/lang/golang with feeds/splitdns/golang
# Config:
#   - openwrt-24.10.5v0.1.config from this repo, copied to buildroot as .config then make defconfig
###############################################################################

# ---- user-tunable env vars ----
: "${OPENWRT_REPO:=https://github.com/nicky1605/openwrt.git}"
: "${OPENWRT_BRANCH:=openwrt-24.10}"
: "${OPENWRT_TAG:=v24.10.5}"                    # try checkout tag; fallback to branch HEAD if not found
: "${SPLITDNS_FEED_URL:=https://github.com/nicky1605/openwrt-splitdns-feed.git}"

: "${WORKDIR:=$PWD/workdir}"                    # workspace directory
: "${BUILDROOT_DIR:=$WORKDIR/openwrt}"          # OpenWrt buildroot path
: "${CONFIG_FILE:=$PWD/openwrt-24.10.5v0.1.config}"

: "${JOBS:=$(nproc)}"
: "${V:=}"                                      # set V=s for verbose build
: "${MAKE_FLAGS:=}"                             # extra make flags, e.g. "IGNORE_ERRORS=1"
: "${CLEAN:=0}"                                 # 1 to make distclean before applying config

# ---- helpers ----
log() { echo -e "\033[1;32m[build]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*" >&2; }
die() { echo -e "\033[1;31m[err ]\033[0m $*" >&2; exit 1; }

require_file() {
  [[ -f "$1" ]] || die "Missing file: $1"
}

ensure_line_in_file() {
  local line="$1" file="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >>"$file"
}

git_clone_or_update() {
  local url="$1" branch="$2" dir="$3"
  if [[ -d "$dir/.git" ]]; then
    log "Updating existing repo: $dir"
    git -C "$dir" fetch --all --tags --prune
    git -C "$dir" checkout "$branch"
    git -C "$dir" pull --ff-only || true
  else
    log "Cloning repo: $url (branch: $branch) -> $dir"
    mkdir -p "$(dirname "$dir")"
    git clone --depth 1 --branch "$branch" "$url" "$dir"
    # fetch tags too (in case OPENWRT_TAG exists)
    git -C "$dir" fetch --tags --depth 1 || true
  fi
}

try_checkout_tag() {
  local dir="$1" tag="$2"
  if git -C "$dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    log "Checking out tag: $tag"
    git -C "$dir" checkout -f "$tag"
    return 0
  fi
  warn "Tag '$tag' not found locally; keep branch HEAD."
  return 1
}

# ---- main ----
main() {
  require_file "$CONFIG_FILE"

  log "WORKDIR: $WORKDIR"
  mkdir -p "$WORKDIR"

  # 1) Get baseline OpenWrt buildroot
  git_clone_or_update "$OPENWRT_REPO" "$OPENWRT_BRANCH" "$BUILDROOT_DIR"
  try_checkout_tag "$BUILDROOT_DIR" "$OPENWRT_TAG" || true

  cd "$BUILDROOT_DIR"

  # 2) Optional clean
  if [[ "$CLEAN" == "1" ]]; then
    log "Running make distclean"
    make distclean
  fi

  # 3) Add splitdns feed (idempotent)
  log "Ensuring splitdns feed exists in feeds.conf.default"
  ensure_line_in_file "src-git splitdns $SPLITDNS_FEED_URL" "feeds.conf.default"

  # 4) Update feeds & install
  log "Updating all feeds"
  ./scripts/feeds update -a

  log "Installing all feeds packages"
  ./scripts/feeds install -a

  # 5) Override golang packaging layer
  #    rm -rf feeds/packages/lang/golang
  #    ln -sfn "$(pwd)/feeds/splitdns/golang" feeds/packages/lang/golang
  log "Overriding feeds/packages/lang/golang with feeds/splitdns/golang"
  if [[ ! -d "feeds/splitdns/golang" ]]; then
    die "feeds/splitdns/golang not found. Did feeds update succeed?"
  fi
  rm -rf "feeds/packages/lang/golang"
  ln -sfn "$(pwd)/feeds/splitdns/golang" "feeds/packages/lang/golang"

  log "Refreshing packages feed after golang override"
  ./scripts/feeds update packages
  ./scripts/feeds install -a -p packages

  # 6) Apply config: copy provided config as .config, then defconfig
  log "Applying config: $CONFIG_FILE -> .config"
  cp -f "$CONFIG_FILE" ".config"

  log "Running make defconfig"
  make defconfig

  # 7) Full build
  log "Building firmware (JOBS=$JOBS) ..."
  # NOTE: V can be set as "s" (V=s) by exporting V=s before running script.
  if [[ -n "$V" ]]; then
    make -j"$JOBS" "V=$V" $MAKE_FLAGS
  else
    make -j"$JOBS" $MAKE_FLAGS
  fi

  # 8) Output artifacts
  log "Build done."
  log "Artifacts usually at: $BUILDROOT_DIR/bin/targets/"
  find "$BUILDROOT_DIR/bin/targets" -maxdepth 4 -type f \
    \( -name "*.img.gz" -o -name "*.vmdk" -o -name "*.vhdx" -o -name "*.tar.gz" \) \
    -print | sed 's/^/[out ] /' || true
}

main "$@"
