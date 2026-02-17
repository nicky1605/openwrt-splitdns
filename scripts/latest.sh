#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# openwrt-splitdns build_v0.2.sh
#
# Baseline:
#   - OpenWrt v24.10.5 (from https://github.com/nicky1605/openwrt, branch openwrt-24.10)
# Feeds:
#   - src-git splitdns https://github.com/nicky1605/openwrt-splitdns-feed.git
# Special:
#   - override feeds/packages/lang/golang with feeds/splitdns/golang
#   - Strategy A: force v2ray-geodata from splitdns feed (remove packages' installed tree)
# Rootfs:
#   - set default opkg distfeeds to OpenWrt USTC mirror
# Config:
#   - default to configs/openwrt-24.10.5/latest.config (copied to buildroot as .config then make defconfig)
###############################################################################

# IMPORTANT: scripts/latest.sh lives in repo_root/scripts/.
# REPO_ROOT must point to repo root, not scripts/.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- user-tunable env vars ----
: "${OPENWRT_REPO:=https://github.com/nicky1605/openwrt.git}"
: "${OPENWRT_BRANCH:=openwrt-24.10}"
: "${OPENWRT_TAG:=v24.10.5}"
: "${SPLITDNS_FEED_URL:=https://github.com/nicky1605/openwrt-splitdns-feed.git}"

: "${WORKDIR:=$REPO_ROOT/workdir}"
: "${BUILDROOT_DIR:=$WORKDIR/openwrt}"
: "${CONFIG_FILE:=$REPO_ROOT/configs/openwrt-24.10.5/latest.config}"

: "${JOBS:=$(nproc)}"
: "${V:=}"                      # set V=s for verbose build
: "${MAKE_FLAGS:=}"
: "${CLEAN:=0}"

# ---- helpers ----
log()  { echo -e "\033[1;32m[build]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[err ]\033[0m $*" >&2; exit 1; }

require_file() { [[ -f "$1" ]] || die "Missing file: $1"; }

ensure_line_in_file() {
  local line="$1" file="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >>"$file"
}

git_clone_or_update() {
  local url="$1" branch="$2" dir="$3"

  # Case A: already a git repo
  if [[ -d "$dir/.git" ]]; then
    log "Updating existing repo: $dir"
    git -C "$dir" fetch --all --tags --prune
    git -C "$dir" checkout "$branch"
    git -C "$dir" pull --ff-only || true
    return 0
  fi

  # Case B: dir exists but not a git repo (e.g. restored from cache) -> wipe and re-clone
  if [[ -e "$dir" ]]; then
    warn "Directory exists but is not a git repo, removing: $dir"
    rm -rf "$dir"
  fi

  log "Cloning repo: $url (branch: $branch) -> $dir"
  mkdir -p "$(dirname "$dir")"
  git clone --depth 1 --branch "$branch" "$url" "$dir"
  git -C "$dir" fetch --tags --prune || true
}


try_checkout_tag() {
  local dir="$1" tag="$2"
  log "Trying to checkout tag: $tag"
  git -C "$dir" fetch --force --prune origin "refs/tags/$tag:refs/tags/$tag" 2>/dev/null || true
  if git -C "$dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    git -C "$dir" checkout -f "$tag"
    return 0
  fi
  warn "Tag '$tag' not found; keep branch HEAD."
  return 1
}

print_error_summary() {
  local logfile="$1"
  warn "Build failed. Error summary from log: $logfile"

  # 1) Common key error lines (last 200 entries)
  grep -nE \
    "ERROR:|failed to build|cannot stat|No such file|Permission denied|cp: cannot|install: cannot|make(\[[0-9]+\])?: \*\*\*|Error [0-9]+" \
    "$logfile" | tail -n 200 || true

  # 2) Context at the end (last 120 lines)
  warn "----- tail -n 120 (context) -----"
  tail -n 120 "$logfile" || true
  warn "----- end context -----"
}

main() {
  require_file "$CONFIG_FILE"

  log "REPO_ROOT:      $REPO_ROOT"
  log "WORKDIR:        $WORKDIR"
  log "BUILDROOT_DIR:  $BUILDROOT_DIR"
  log "CONFIG_FILE:    $CONFIG_FILE"
  mkdir -p "$WORKDIR"

  # Log file (for both local + CI)
  mkdir -p "$REPO_ROOT/logs"
  BUILD_LOG="$REPO_ROOT/logs/build-$(date +%Y%m%d-%H%M%S).txt"
  log "Build log:      $BUILD_LOG"

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
  log "Overriding feeds/packages/lang/golang with feeds/splitdns/golang"
  [[ -d "feeds/splitdns/golang" ]] || die "feeds/splitdns/golang not found. Did feeds update succeed?"
  rm -rf "feeds/packages/lang/golang"
  ln -sfn "$(pwd)/feeds/splitdns/golang" "feeds/packages/lang/golang"

  log "Refreshing packages feed after golang override"
  ./scripts/feeds update packages
  ./scripts/feeds install -a -p packages

  # v2ray-geodata: Strategy A (force splitdns feed version)
  log "Forcing v2ray-geodata to use splitdns feed (Strategy A)"
  rm -rf "package/feeds/packages/v2ray-geodata" || true
  rm -rf "package/feeds/splitdns/v2ray-geodata" || true
  ./scripts/feeds install -p splitdns v2ray-geodata || die "Failed to install v2ray-geodata from splitdns feed"

  # Rootfs overlay: default opkg feeds -> OpenWrt USTC mirror
  log "Writing default /etc/opkg/distfeeds.conf (OpenWrt USTC mirror)"
  mkdir -p "files/etc/opkg"
  cat > "files/etc/opkg/distfeeds.conf" <<'EOF'
src/gz openwrt_core      https://mirrors.ustc.edu.cn/openwrt/releases/24.10.5/targets/x86/64/packages
src/gz openwrt_base      https://mirrors.ustc.edu.cn/openwrt/releases/packages-24.10/x86_64/base
src/gz openwrt_luci      https://mirrors.ustc.edu.cn/openwrt/releases/packages-24.10/x86_64/luci
src/gz openwrt_packages  https://mirrors.ustc.edu.cn/openwrt/releases/packages-24.10/x86_64/packages
src/gz openwrt_routing   https://mirrors.ustc.edu.cn/openwrt/releases/packages-24.10/x86_64/routing
src/gz openwrt_telephony https://mirrors.ustc.edu.cn/openwrt/releases/packages-24.10/x86_64/telephony
EOF

  # 6) Apply config
  log "Applying config: $CONFIG_FILE -> .config"
  cp -f "$CONFIG_FILE" ".config"

  log "Running make defconfig"
  make defconfig

  # Optional: also export the final .config to repo logs for CI artifact
  cp -f ".config" "$REPO_ROOT/logs/openwrt.defconfig" || true

  # 7) Full build (fast) + log capture
  log "Building firmware (JOBS=$JOBS) ..."
  set +e
  if [[ -n "$V" ]]; then
    make -j"$JOBS" "V=$V" $MAKE_FLAGS 2>&1 | tee "$BUILD_LOG"
    rc=${PIPESTATUS[0]}
  else
    make -j"$JOBS" $MAKE_FLAGS 2>&1 | tee "$BUILD_LOG"
    rc=${PIPESTATUS[0]}
  fi
  set -e

  if [[ $rc -ne 0 ]]; then
    print_error_summary "$BUILD_LOG"
    die "Build failed."
  fi

  # 8) Output artifacts
  log "Build done."
  log "Artifacts usually at: $BUILDROOT_DIR/bin/targets/"
  find "$BUILDROOT_DIR/bin/targets" -maxdepth 4 -type f \
    \( -name "*.img.gz" -o -name "*.vmdk" -o -name "*.vhdx" -o -name "*.qcow2" -o -name "*rootfs.tar.gz" -o -name "sha256sums" -o -name "*.manifest" \) \
    -print | sed 's/^/[out ] /' || true
}

main "$@"
