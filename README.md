# openwrt-splitdns

Deterministic OpenWrt build environment with SplitDNS-oriented package feed.

---

## 📌 Project Goal

**openwrt-splitdns** is designed as a reproducible, upgrade-safe OpenWrt build system.

Core principles:

- Use **official OpenWrt stable releases** as the absolute baseline
- Do **NOT modify toolchain / target / kernel / core feeds**
- All customizations injected exclusively via **independent feed**
- Ensure long-term maintainability and minimal fork drift

Baseline version:
OpenWrt v24.10.5
Target: x86_64 (musl)

---

## 🧱 Architecture Philosophy

This project intentionally avoids:

❌ Forking OpenWrt core  
❌ Patching toolchain  
❌ Modifying kernel logic  

Instead, it follows:

✅ Clean baseline  
✅ Feed-based extension  
✅ Commit-pinned packages  

This guarantees:

- Predictable upgrades
- CI/CD compatibility
- Minimal maintenance overhead

---

## 📦 SplitDNS Feed

External feed source:
src-git splitdns https://github.com/nicky1605/openwrt-splitdns-feed.git

Responsibilities of the feed:

- Provide packages not present upstream
- Lock third-party packages to known commits
- Maintain license / compliance metadata
- Track upstream via git subtree

---

## 🚨 mosdns & Golang Compatibility

### Problem

`mosdns` requires:
Go >= 1.24

But OpenWrt 24.10.x packages feed typically provides older Go versions.

---

### ✅ Solution Strategy

We **do NOT modify OpenWrt toolchain**.

Instead:

Override the golang packaging layer:

```bash
rm -rf feeds/packages/lang/golang
ln -sfn "$(pwd)/feeds/splitdns/golang" feeds/packages/lang/golang
./scripts/feeds update packages
./scripts/feeds install -a -p packages
Result:

✔ Baseline integrity preserved
✔ mosdns builds correctly
🏗 Build Process

One-shot build:
./build.sh

Verbose diagnostic build:
V=s ./build.sh

Clean rebuild:
CLEAN=1 ./build.sh

⚙ Baseline Config
Default configuration file:
openwrt-24.10.5v0.1.config
Usage inside buildroot:
Copied as .config
Expanded via make defconfig
This ensures deterministic package selection.

🧪 Validation Scope

Validated environment:
Baseline: OpenWrt v24.10.5
Target: x86_64
Build Mode: full firmware build

Feed Packages:

✔ mosdns
✔ luci-app-mosdns
✔ v2dat
✔ Argon theme
✔ diskman / netwizard / syscontrol

🧭 Compilation Strategy

Normal builds:
make -j$(nproc)

Only use single-thread when debugging:
make -j1 V=s

🚀 Future Roadmap

Planned improvements:
GitHub Actions automated firmware builds
Artifact publishing
Versioned release images
Build cache optimization
Intranet Hosts Manager
MosDNS Default config

⚖ Licensing & Compliance

OpenWrt components follow upstream licenses
Third-party packages maintain original LICENSE files
Feed repository responsible for license tracking

👤 Maintainer
Project maintained by:
Nicky Liu && OpenAI


⚠ Disclaimer
This project is a build environment wrapper, not an OpenWrt fork.
All baseline behavior follows upstream OpenWrt.
Custom functionality comes exclusively from external feeds.

