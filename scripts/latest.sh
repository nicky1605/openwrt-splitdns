#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# openwrt-splitdns build_v0.2.sh (latest)
#
# Baseline:
#   - OpenWrt v24.10.5 (from https://github.com/nicky1605/openwrt, branch openwrt-24.10)
# Feeds:
#   - src-git splitdns https://github.com/nicky1605/openwrt-splitdns-feed.git
# Special:
#   - override feeds/packages/lang/golang with feeds/splitdns/golang
#   - Strategy A: force v2ray-geodata from splitdns feed (remove packages' installed tree)
# Rootfs:
#   - set default opkg distfeeds to OpenWrt USTC mirror (no ImmortalWrt sources)
# Config:
#   - default to configs/openwrt-24.10.5/latest.config (copied to buildroot as .config then make defconfig)
###############################################################################

# IMPORTANT: scripts/latest.sh lives in repo_root/scripts/.
# REPO_ROOT must point to repo root, not scripts/.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- user-tunable env vars ----
: "${OPENWRT_REPO:=https://github.com/nicky1605/openwrt.git}"
: "${OPENWRT_BRANCH:=openwrt-24.10}"
: "${OPENWRT_TAG:=v24.10.5}"                    # prefer tag; fallback to branch HEAD if not found
: "${SPLITDNS_FEED_URL:=https://github.com/nicky1605/openwrt-splitdns-feed.git}"

: "${WORKDIR:=$REPO_ROOT/workdir}"              # workspace directory
: "${BUILDROOT_DIR:=$WORKDIR/openwrt}"          # OpenWrt buildroot path
: "${CONFIG_FILE:=$REPO_ROOT/configs/openwrt-24.10.5/latest.config}"

: "${JOBS:=$(nproc)}"
: "${V:=}"                                      # set V=s for verbose build
: "${MAKE_FLAGS:=}"                             # extra make flags, e.g. "IGNORE_ERRORS=1"
: "${CLEAN:=0}"                                 # 1 to make distclean before applying config

# ---- helpers ----
log()  { echo -e "\033[1;32m[build]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[err ]\033[0m $*" >&2; exit 1; }

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
    # Shallow clone for speed (CI), but we will explicitly fetch tag later if needed.
    git clone --depth 1 --branch "$branch" "$url" "$dir"
    git -C "$dir" fetch --tags --prune || true
  fi
}

try_checkout_tag() {
  local dir="$1" tag="$2"

  # In shallow clones, tags may exist but the tagged commit may not be present.
  # Fetch the tag explicitly (best-effort), then checkout.
  log "Trying to checkout tag: $tag"
  git -C "$dir" fetch --force --prune origin "refs/tags/$tag:refs/tags/$tag" 2>/dev/null || true

  if git -C "$dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    git -C "$dir" checkout -f "$tag"
    return 0
  fi

  warn "Tag '$tag' not found; keep branch HEAD."
  return 1
}

main() {
  require_file "$CONFIG_FILE"

  log "REPO_ROOT:      $REPO_ROOT"
  log "WORKDIR:        $WORKDIR"
  log "BUILDROOT_DIR:  $BUILDROOT_DIR"
  log "CONFIG_FILE:    $CONFIG_FILE"
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
  log "splitdns feed HEAD:"
  git -C "feeds/splitdns" log -1 --oneline || true


  log "Installing all feeds packages"
  ./scripts/feeds install -a

  # 5) Override golang packaging layer
  log "Overriding feeds/packages/lang/golang with feeds/splitdns/golang"
  if [[ ! -d "feeds/splitdns/golang" ]]; then
    die "feeds/splitdns/golang not found. Did feeds update succeed?"
  fi
  rm -rf "feeds/packages/lang/golang"
  ln -sfn "$(pwd)/feeds/splitdns/golang" "feeds/packages/lang/golang"

  log "Refreshing packages feed after golang override"
  ./scripts/feeds update packages
  ./scripts/feeds install -a -p packages

  # --------------------------------------------------------------------------
  # v2ray-geodata: Strategy A (force splitdns feed version)
  # Remove packages feed installed tree, then install from splitdns explicitly.
  # --------------------------------------------------------------------------
  log "Forcing v2ray-geodata to use splitdns feed (Strategy A)"
  rm -rf "package/feeds/packages/v2ray-geodata" || true
  rm -rf "package/feeds/splitdns/v2ray-geodata" || true
  ./scripts/feeds install -p splitdns v2ray-geodata || die "Failed to install v2ray-geodata from splitdns feed"

  # Quick sanity check (best-effort)
  if [[ -e "package/feeds/splitdns/v2ray-geodata/Makefile" ]]; then
    log "OK: v2ray-geodata Makefile exists under package/feeds/splitdns"
  else
    warn "v2ray-geodata not found under package/feeds/splitdns (check feeds install output)"
  fi

  # --------------------------------------------------------------------------
  # Rootfs overlay: default opkg feeds -> OpenWrt USTC mirror (no ImmortalWrt)
  # This writes into buildroot/files/..., which is included into the firmware.
  # --------------------------------------------------------------------------
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

  # 6) Apply config: copy provided config as .config, then defconfig
  log "Applying config: $CONFIG_FILE -> .config"
  cp -f "$CONFIG_FILE" ".config"

  log "Running make defconfig"
  make defconfig

  # 7) Full build
  log "Building firmware (JOBS=$JOBS) ..."

  set +e
  if [[ -n "$V" ]]; then
    make -j"$JOBS" "V=$V" $MAKE_FLAGS
    rc=$?
  else
    make -j"$JOBS" $MAKE_FLAGS
    rc=$?
  fi
  set -e

  if [[ $rc -ne 0 ]]; then
    warn "World build failed (rc=$rc). Re-running luci-app-syscontrol with -j1 V=s for diagnosis..."
    make package/feeds/splitdns/luci-app-syscontrol/{clean,compile} -j1 V=s || true
    die "Build failed. See verbose syscontrol logs above."
  fi


  # 8) Output artifacts
  log "Build done."
  log "Artifacts usually at: $BUILDROOT_DIR/bin/targets/"
  find "$BUILDROOT_DIR/bin/targets" -maxdepth 4 -type f \
    \( -name "*.img.gz" -o -name "*.vmdk" -o -name "*.vhdx" -o -name "*.tar.gz" \) \
    -print | sed 's/^/[out ] /' || true
}

main "$@"
