# Building the Morke tunnel extension

This file is part of the Corresponding Source. GPLv3 § 1 defines it as *"all the
source code needed to generate, install, and … run the object code and to modify
the work, **including scripts to control those activities**"* — so the build
recipe is owed, not merely helpful. Everything needed to go from this repository
plus a sing-box checkout to a loadable `MorkeTunnel.appex` is written down here.

Read [README.md](README.md) first for what this repository is and is not.

---

## 1. The pin

**sing-box `v1.14.4`, plus the Morke patch series** — upstream tag `v1.14.4` in
[`SagerNet/sing-box`](https://github.com/SagerNet/sing-box/tree/v1.14.4), commit
`c005f35300ce76427dc285481ec5695f5b179cd2`, with `singbox-fork/0001-morke-trim.patch`
applied on top.

**We build a modified sing-box, and say so here because GPLv3 § 5(a) requires it.**
The patch is dated `2026-09-23`, `2026-10-04` and `2026-11-14`, every file it touches carries a
modification notice in its own header, and § 2 below is the recipe that turns the upstream
commit plus that patch into the exact engine we ship. The upstream tag alone will
**not** reproduce our artefact — see § 2.4.

| Artefact | Value |
|---|---|
| Upstream tag | `v1.14.4` |
| Upstream commit | `c005f35300ce76427dc285481ec5695f5b179cd2` |
| Patch | `singbox-fork/0001-morke-trim.patch` |
| Patch SHA-256 | `ded97a1e8e4195e330ff71c0140367d26a9369ce31861cb03758644b98c76486` |
| Version stamped into `constant.Version` | `1.14.4-morke.1` |

**Pin the commit, not the tag.** Upstream has moved a release tag after the fact:
`v1.13.13`, the base of our previous engine, pointed at
`83b73048ff772b919af18653b78ffeaa2d48b66e` when we built from it on 2026-09-04 and
points at `78b2e12fbdd85e6ec956647d6f79cf0bba85c6ba` today (read 2026-09-23). The old
commit is still served by GitHub, but no tag reaches it any more, so a plain
`git clone --branch` no longer contains it. The recipe in § 2.1 therefore fetches
the commit by its hash.

### What the patch changes, and why

Eleven files — ten modified, one added. Nothing is added to the engine's
behaviour; the patch removes surface this client cannot reach, and one write this
client must not leave behind, and records that it did. Every change was measured on a real build: the package set `gomobile bind`
compiles for iOS and macOS (`GOOS=ios|darwin go list -deps -tags … ./experimental/libbox`),
and the symbol tables of the resulting `ios-arm64` and `macos-arm64_x86_64` slices. The patch was
first written against `v1.14.1` (2026-09-23) and re-derived against `v1.14.4` (2026-11-14): every
file it touches was compared with upstream's changes between the two, and the package set was
classified again.

- **`include/registry.go`** — the protocol registry. Upstream registers every
  protocol it ships. Morke's client refuses all but four egress types
  (`vless`, `direct`, `block`, `dns`), one ingress type (`tun`), no `endpoints`,
  no `services`, no `certificate_providers` and no `experimental` key but
  `cache_file`, in a fail-closed check that runs before any configuration reaches
  libbox. Everything outside that set was unreachable code in a shipped build, so
  it is no longer registered: the SOCKS, HTTP, mixed, Shadowsocks, Snell, VMess,
  Trojan, Naive, ShadowTLS, VLESS, AnyTLS, redirect and TProxy inbounds; the
  SOCKS, HTTP, Shadowsocks, Snell, VMess, Trojan, Tor, SSH, ShadowTLS, AnyTLS,
  bridge, selector and urltest outbounds; the `api` and `ssm-api` services; the
  `cloudflare-origin-ca` certificate provider. An unexpected type now fails to
  decode instead of being constructed.
- **`cmd/internal/build_libbox/main.go`** — the build script. The optional-feature
  tags drop to `with_gvisor,with_utls,badlinkname,tfogo_checklinkname0`
  (+ `grpcnotrace` on Darwin, + `with_low_memory` off macOS), the Apple bind target
  drops the two tvOS slices nothing links, and the version stamp stops shelling out
  to `git describe` so the build no longer depends on VCS state.
- **`experimental/libbox/native_shell_session.go`** and its stub — the build
  constraint excludes both Apple platforms: iOS since 2026-09-23, macOS since
  2026-11-14. Upstream builds the file on Linux, Android, macOS and iOS, which links
  the Tailscale SSH server — and through it the whole Tailscale client and
  `wireguard-go` — into every Apple build, whatever `with_tailscale` says. The two
  functions it defines are called only by a host application that runs a shell
  server; neither the iOS extension nor the macOS system extension does.
- **`experimental/libbox/bridge_service_darwin.go`** and `bridge_stub.go` — the
  same for `NewBridgeService`, a privileged L3 forwarder that upstream supports on
  iOS only when jailbroken: the file now builds nowhere (`//go:build ignore`), and
  the stub covers every platform but Linux.
- **`daemon/started_service_tailscale_ssh.go`** and a new
  **`daemon/started_service_tailscale_ssh_stub.go`** — the gRPC method that opens
  an SSH session to a Tailscale peer builds only with `with_tailscale`; otherwise
  the stub answers it. This is the pattern upstream already uses for USB/IP. A
  build without Tailscale cannot construct the endpoint the method needs, so it
  could never succeed; ungated, it still linked `golang.org/x/crypto/ssh`.
- **`experimental/libbox/log.go`** — two changes. `CreateZipArchive` no longer
  offers its `encrypt` mode, which seals a report archive to SagerNet's own `age`
  recipient and links `filippo.io/age` and `filippo.io/hpke`. It is called only by
  a host application exporting reports upstream; this one does not. And
  `saveConfigSnapshot` writes nothing (added 2026-10-04, version `morke.2`):
  upstream writes the whole configuration to `<basePath>/configuration.json`, mode
  `0666`, on every start, and nothing ever deletes it. A Morke configuration
  carries the account's live proxy credential, which the client otherwise keeps
  only in the Keychain. Nothing reads the file back for behaviour — the engine
  starts from the configuration in memory, and the only reader copies the file
  into a crash, out-of-memory or power report and skips it when it is absent — so
  the reports simply go without it. The function and its call stay, so upstream's
  shape stays recognisable.
- **`experimental/libbox/oom_report.go`** — an out-of-memory report no longer
  contains the engine's log or a `connections.json` listing every open and
  recently closed connection with its source, destination and domain. `v1.14`
  added both; `v1.13.13`'s report had neither. A traffic record on disk is
  something this client does not keep, whatever the reason.
- **`service/powerreport/device_darwin.m`** (added 2026-11-14) — the load-time
  constructor `v1.14.4` added is removed. On iOS it ran when the library loaded,
  whatever the host asked for, and switched on the device's battery monitoring
  for the life of the process. The battery is read only by the power-report
  recorder, which this client never enables; the reading function stays and,
  unmonitored, reports what it reports on a device without a battery.

The previous patch also added `cmd/internal/sizeprobe`, a measuring program. It is
not carried forward: the measurements above need no code in the tree.

### Tags kept, and one tag no longer kept

`with_gvisor` is required: the iOS kill switch sets `includeAllNetworks`, with which
sing-box's `system` and `mixed` TUN stacks are incompatible, so `tun.stack` becomes
`gvisor`. `with_utls` is required: REALITY is built on uTLS, and removing it removes
the proxy.

**`with_clash_api` is removed in this version.** The `v1.13.13` patch had to keep
it: that version turned the platform log writer libbox always passes into a Clash
API server, so a build without the tag failed every start. Since `v1.14.1` it builds the
Clash API server only from an `experimental.clash_api` block, and its daemon imports
`experimental/clashmode` instead of `experimental/clashapi`, so the tag now unlinks
the control server entirely. Measured: configurations of exactly the shapes the
client sends decode and construct without it — through `box.New` with the platform
log writer libbox always passes, the path that failed on `v1.13.13` — and one
carrying `experimental.clash_api` is refused with
`clash api is not included in this build`.

---

## 2. Build `Libbox.xcframework` from source

No prebuilt releases exist; the framework is built from the pinned commit plus the patch.

**Prerequisites**

- Go ≥ 1.25.5 — the published artefact was built with **go1.26.10 darwin/arm64**, the
  toolchain upstream's own `v1.14.4` release uses; with a newer local Go, select it with
  `GOTOOLCHAIN=go1.26.10` (the recipe does), because a different toolchain links a different
  standard library and no digest below will match
- Xcode with the full command-line tools — `xcode-select -p` must point at
  `Xcode.app`, not at the CommandLineTools stub. The published artefact was built
  with **Xcode 27.2 (27B52)**.

> **sing-box uses its own gomobile fork** (`github.com/sagernet/gomobile`),
> installed by `make lib_install` — pinned at `v0.1.13` for this version (as for `v1.14.1`). Upstream
> `golang.org/x/mobile/cmd/gomobile` is **incompatible**. The Makefile target is
> **`lib_apple`** — there is no `lib_ios` target.

### 2.1 The recipe

```sh
git init sing-box && cd sing-box
git remote add origin https://github.com/SagerNet/sing-box.git
git fetch --depth 1 origin c005f35300ce76427dc285481ec5695f5b179cd2
git checkout FETCH_HEAD
export GOTOOLCHAIN=go1.26.10

# 1. Apply the Morke patch series
patch -p1 < <path-to-this-repo>/singbox-fork/0001-morke-trim.patch

# 2. Install SagerNet's gomobile/gobind fork into GOPATH/bin
make lib_install
export PATH="$PATH:$(go env GOPATH)/bin"

# 3. Build the Apple xcframework (iOS device + simulator, macOS)
#    Runs: go run ./cmd/internal/build_libbox -target apple
#    Takes a few minutes; downloads many Go modules on first run.
make lib_apple

# 4. Place the output where the Xcode project expects it
mv Libbox.xcframework <morke-tree>/Frameworks/Libbox.xcframework
```

`gomobile` itself is BSD-3-Clause. Its licence governs the **tool**, not the
sing-box code it wraps; the output is GPL-3.0-or-later like its input.

### 2.2 What it produces

Three slices, not five. Upstream's `build_libbox` also emits `tvos-arm64` and
`tvos-arm64_x86_64-simulator`; there is no tvOS target in the Xcode project, so
those two were never linked into any shipped binary.

| Slice | `Libbox` (static library) |
|---|---|
| `ios-arm64` | 47 309 344 bytes |
| `ios-arm64_x86_64-simulator` | 92 165 872 bytes |
| `macos-arm64_x86_64` | 89 525 584 bytes |

**The product is a static library.**
`Libbox.xcframework/ios-arm64/Libbox.framework/Libbox` is an `ar` archive —
`file(1)` says so. There is no dynamic-linking ambiguity here, which is why
§ 5(c) reaches the whole extension.

### 2.3 Verifying the artefact — this build IS reproducible

Two builds of this source, from different directories and with separate Go build
caches, produce `Libbox` files whose object members are byte-identical. They can
differ in two places, both inside the `__.SYMDEF` symbol index that `libtool`
writes at the head of each `ar` archive — one archive in the `ios-arm64` slice,
one per architecture in the two universal slices:

- the ASCII mtime in the index's member header, which `libtool` stamps with the
  build time;
- the alignment pad after the last symbol name in the index's string table, which
  `libtool` never initialises — it may hold zeros in one build and stray bytes in
  the next.

Blank the member mtimes and zero that pad, and the digest is stable.

`singbox-fork/libbox-digest.py` does exactly that and nothing else — 79 lines,
stdlib only, no network, readable in a minute:

```sh
python3 singbox-fork/libbox-digest.py \
  Libbox.xcframework/*/Libbox.framework/Versions/A/Libbox
```

Expected, for the engine shipped with this tag:

| Slice | Canonical SHA-256 |
|---|---|
| `ios-arm64` | `90c1a0941ceeaacd415d13864e017af8f031a67ad3746f7c069da075c66ad4c5` |
| `ios-arm64_x86_64-simulator` | `91f0957a4bc7d0411c6b2effbc484eabcff9b7f104ed5d6ba562ab9962a9f729` |
| `macos-arm64_x86_64` | `c43d25efecc048bf4bbe378d89c5aaa2c551c9cdfe2d87b66f377def9dd48085` |

Measured on two builds from two fresh fetches of the commit, in separate directories with
separate Go build caches (2026-11-14). The previous engine, `1.14.1-morke.2`, was
`4a3a7fcf…358b` · `e2aa6512…6b37` · `c5f40142…629e`.

A plain `shasum -a 256` of the same files will **not** match between builds, by
exactly those bytes. That is a property of `libtool`, not of the source.

**A correction to the previous release, 2026-10-04.** Until 2026-10-04 the script
blanked only the mtimes, and this section said two builds differ **only** there.
That held for the `1.14.1-morke.1` engine by luck, not by construction: both of
its builds happened to get a zero pad. Two builds of `1.14.1-morke.2` did not —
one carried stray bytes in the `ios-arm64` pad, the other in the simulator
slice's second architecture — while all of their object members were identical.
The script now also zeroes the pad. Zeroing a pad that is already zero changes
nothing, so every digest published earlier is unchanged under the new method:
the three `1.14.1-morke.1` values (`64d894dd…c6b3`, `7f720677…b804`,
`3cc9db0a…9d11`) and the `v1.13.13` `ios-arm64` value below, re-measured on the
archived engines.

**A correction to the previous release.** Until 2026-09-23 the script blanked only
the first archive it found, so for the two universal slices it left the second
architecture's timestamp in place. The `ios-arm64` digest published for `v1.13.13`
(`914762d2…e9c4`) was and remains reproducible — that slice holds one archive, and
the corrected script prints the same value for it. The two universal-slice digests
published alongside it were not reproducible by anyone else.

### 2.4 If you build the upstream tag instead

You will get a different, larger artefact, and no digest above will match — that is
correct and expected. The upstream tag is the base, not the engine we ship. Apply
the patch.

---

## 3. Build settings for the `MorkeTunnel` target

The extension is an iOS app-extension target (`com.apple.product-type.app-extension`)
in an Xcode project that also builds the closed-source client. That project file
is not published, because it configures targets this licence does not cover. The
target's own build configuration is reproduced here **verbatim** instead, which
is what § 1 actually asks for — the settings that produced the object code.

Both configurations, copied from the project's `XCBuildConfiguration` blocks for
the `MorkeTunnel` target as of `MARKETING_VERSION = 26.0.0` / `CURRENT_PROJECT_VERSION = 1`:

```
CLANG_COVERAGE_MAPPING                  = NO
CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = NO
CODE_SIGN_ENTITLEMENTS                  = MorkeTunnel/MorkeTunnel.entitlements
CODE_SIGN_IDENTITY                      = "Apple Development"
CODE_SIGN_STYLE                         = Automatic
CURRENT_PROJECT_VERSION                 = 1
DEVELOPMENT_TEAM                        = VM3XX8889Q
ENABLE_DEBUG_DYLIB                      = NO
GENERATE_INFOPLIST_FILE                 = NO
INFOPLIST_FILE                          = MorkeTunnel/Info.plist
INFOPLIST_KEY_CFBundleDisplayName       = Morke
IPHONEOS_DEPLOYMENT_TARGET              = 17.0
LD_RUNPATH_SEARCH_PATHS                 = ("$(inherited)",
                                           "@executable_path/Frameworks",
                                           "@executable_path/../../Frameworks")
MARKETING_VERSION                       = 26.0.0
PRODUCT_BUNDLE_IDENTIFIER               = tech.twodice.morke.tunnel
PRODUCT_NAME                            = "$(TARGET_NAME)"
SKIP_INSTALL                            = YES
SUPPORTED_PLATFORMS                     = "iphoneos iphonesimulator"
SUPPORTS_MACCATALYST                    = NO
SWIFT_APPROACHABLE_CONCURRENCY          = YES
SWIFT_OBJC_BRIDGING_HEADER              = MorkeTunnel/MorkeTunnel-Bridging-Header.h
SWIFT_STRICT_CONCURRENCY                = complete
SWIFT_VERSION                           = 6.0
TARGETED_DEVICE_FAMILY                  = 1
```

Debug and Release are identical apart from Apple's own configuration-level
defaults (optimisation level, `DEBUG` preprocessor flag, debug information
format), which the project inherits rather than sets per target.

**Three of these are load-bearing and will cost you a day if you change them:**

- **`ENABLE_DEBUG_DYLIB = NO`.** Xcode 16+ splits an app's main binary into a
  debug dylib by default. With it on, the extension fails to launch.
- **`GENERATE_INFOPLIST_FILE = NO` + the checked-in `Info.plist`.** The plist
  must set `CFBundlePackageType = XPC!`. A generated plist does not, and the
  extension then crashes at launch on iOS 26 with a message that points nowhere
  near the cause.
- **No `SWIFT_DEFAULT_ACTOR_ISOLATION`.** The rest of the tree defaults to
  `MainActor`; this target must not. Every `LibboxPlatformInterface` method is
  called from a Go goroutine on an arbitrary C thread, and a `MainActor` default
  turns each of those into an isolation violation.

### Bundle configuration

`Info.plist` (checked in, not generated):

```xml
<key>CFBundlePackageType</key>       <string>XPC!</string>
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.networkextension.packet-tunnel</string>
  <key>NSExtensionPrincipalClass</key>
  <string>PacketTunnelProvider</string>
</dict>
```

`PacketTunnelProvider` is pinned with `@objc(PacketTunnelProvider)` so
`NSExtensionPrincipalClass` resolves regardless of the Swift module name.

`MorkeTunnel.entitlements`:

```xml
com.apple.developer.networking.networkextension = [packet-tunnel-provider]
com.apple.security.application-groups          = [group.tech.twodice.morke]
keychain-access-groups                         = [$(AppIdentifierPrefix)tech.morke.shared]
```

These identifiers are contracts, not preferences. `AppGroup.appGroupID`,
`SharedKeychain`'s access-group suffix and `TunnelExtensionConstants.bundleID`
must each match their entitlement string exactly; a mismatch produces
`errSecItemNotFound` at tunnel start and no compile error at all. Rebuilding
under your own Team ID means changing all of the identifiers above consistently.

### What the target links

| Link | Kind |
|---|---|
| `Libbox.xcframework` | vendored, built in § 2 above (static `ar` archive) |
| `MorkeShared` | the SwiftPM module in this repository |
| `NetworkExtension.framework` | system |
| `UIKit.framework` | system |
| `libresolv.tbd` | system |
| `WidgetKit.framework` | system — not in the target's link phase; linked through `import WidgetKit` in `PacketTunnelProvider.swift`, whose `stopTunnel` refreshes the app's widget and Control Center control |

**Nothing else may be added to this list.** The Packet-Tunnel process runs under
a tight memory budget, so the extension's link set is a budget, not a module
boundary. `MorkeShared` in particular depends on Foundation, Security and (on
iOS) CryptoKit — all system frameworks — and on **zero** packages.

### Building `MorkeShared`

`MorkeShared/` is a SwiftPM library target with no dependencies. To build it
standalone, place it under `Sources/MorkeShared/` in a package declaring:

```swift
// swift-tools-version: 6.2
.library(name: "MorkeShared", targets: ["MorkeShared"])
.target(name: "MorkeShared")
```

with platforms `.iOS(.v17)`, `.macOS(.v14)`. In the Morke tree it is one target
of a larger local package; the target itself has no package dependencies, so
that declaration is complete.

---

## 4. macOS

The same sources also build `MorkeTunnel (macOS)`, a **system extension**
(`com.apple.product-type.system-extension`) rather than an app extension. The
Morke Mac app embeds it under `Contents/Library/SystemExtensions/`, and it has
been conveyed since 27.0.0 (4), released on 2026-11-17 by direct download
(Developer ID, notarized).

**The host, `MorkeTunnelMac/main.swift`.** A system extension is a standalone
executable rather than a plug-in its host loads, so `main.swift` enters
NetworkExtension's system-extension mode itself (`NEProvider.startSystemExtensionMode()`),
which instantiates `PacketTunnelProvider` from the `NEProviderClasses` map of its
`Info.plist`. Before that it publishes the `NEMachServiceName` as an XPC listener
that accepts only the signed Morke app and carries the tunnel configuration, its
removal and the Kill Switch flag into the extension (`MorkeShared/TunnelControl.swift`,
`MorkeShared/TunnelConfigCache.swift`).

The target's **Release** configuration, the one that is conveyed, copied verbatim
from the project's `XCBuildConfiguration` block for `MorkeTunnel (macOS)` as of
`MARKETING_VERSION = 27.0.0` / `CURRENT_PROJECT_VERSION = 4`:

```
CLANG_COVERAGE_MAPPING                  = NO
CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = NO
CODE_SIGN_ENTITLEMENTS                  = "MorkeTunnel/MorkeTunnel-macOS.entitlements"
"CODE_SIGN_IDENTITY[sdk=macosx*]"       = "Developer ID Application"
CODE_SIGN_STYLE                         = Manual
CURRENT_PROJECT_VERSION                 = 4
DEAD_CODE_STRIPPING                     = YES
DEVELOPMENT_TEAM                        = ""
"DEVELOPMENT_TEAM[sdk=macosx*]"         = VM3XX8889Q
ENABLE_DEBUG_DYLIB                      = NO
ENABLE_HARDENED_RUNTIME                 = YES
GENERATE_INFOPLIST_FILE                 = NO
INFOPLIST_FILE                          = "Config/MorkeTunnel-macOS-Info.plist"
LD_RUNPATH_SEARCH_PATHS                 = ("$(inherited)",
                                           "@executable_path/../Frameworks",
                                           "@loader_path/../Frameworks")
MACOSX_DEPLOYMENT_TARGET                = 14.0
MARKETING_VERSION                       = 27.0.0
MORKE_APP_GROUP                         = group.tech.twodice.morke
MORKE_DISPLAY_NAME                      = Morke
MORKE_KEYCHAIN_GROUP                    = tech.morke.shared
MORKE_NE_PROVIDER                       = "packet-tunnel-provider-systemextension"
PRODUCT_BUNDLE_IDENTIFIER               = tech.twodice.morke.tunnel
PRODUCT_NAME                            = "$(PRODUCT_BUNDLE_IDENTIFIER)"
PROVISIONING_PROFILE_SPECIFIER          = ""
"PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]" = "MorkeTunnel macOS DevID"
REGISTER_APP_GROUPS                     = YES
SDKROOT                                 = macosx
SKIP_INSTALL                            = YES
SUPPORTED_PLATFORMS                     = macosx
SWIFT_APPROACHABLE_CONCURRENCY          = YES
SWIFT_OBJC_BRIDGING_HEADER              = "MorkeTunnel/MorkeTunnel-Bridging-Header.h"
SWIFT_STRICT_CONCURRENCY                = complete
SWIFT_VERSION                           = 6.0
```

`INFOPLIST_FILE` is the Morke tree's path; the file is published as
`macOS/MorkeTunnel-macOS-Info.plist` ([MANIFEST.md](MANIFEST.md) block B). The
`MORKE_*` settings are expanded into the entitlements and the `Info.plist` below.
`CURRENT_PROJECT_VERSION` is the line that moves between releases (one build
counter serves both platforms); at build `5` every other line above is unchanged.

**Debug builds a development variant, "Morke Dev", that is not conveyed.** It
differs from Release in these lines and nothing else:

```
"CODE_SIGN_IDENTITY[sdk=macosx*]"       (not set)
CODE_SIGN_STYLE                         = Automatic
MORKE_APP_GROUP                         = group.tech.twodice.morke.dev
MORKE_DISPLAY_NAME                      = "Morke Dev"
MORKE_KEYCHAIN_GROUP                    = tech.morke.dev.shared
MORKE_NE_PROVIDER                       = packet-tunnel-provider
PRODUCT_BUNDLE_IDENTIFIER               = tech.twodice.morke.dev.tunnel
PRODUCT_NAME                            = tech.twodice.morke.tunnel
PROVISIONING_PROFILE_SPECIFIER          (neither form set)
```

`MorkeShared` selects the matching Debug identifiers with `#if os(macOS) && DEBUG`,
so the settings and the code must move together.

**Three of these are load-bearing on macOS:**

- **`PRODUCT_NAME` resolves to `tech.twodice.morke.tunnel`** in both configurations. An embedded
  system extension's bundle name must equal its bundle identifier for macOS to
  activate it, so the product is `tech.twodice.morke.tunnel.systemextension`.
- **`MORKE_NE_PROVIDER = packet-tunnel-provider-systemextension`** in Release. A
  Developer ID signed system extension claims the `-systemextension` form of the
  Network Extension entitlement; an Apple Development profile allows the plain
  `packet-tunnel-provider` only, which is why Debug differs.
- **`ENABLE_HARDENED_RUNTIME = YES`** with the Developer ID identity: Apple
  notarizes nothing distributed outside the App Store without the hardened runtime.

As on iOS, the target sets no `SWIFT_DEFAULT_ACTOR_ISOLATION` (§ 3).

### What the macOS target compiles and links

The macOS target lists its sources explicitly in the project; it is not a
synchronized group:

| Compiled | From |
|---|---|
| `PacketTunnelProvider.swift`, `SingBoxTunnel.swift`, `ExtensionPlatformInterface.m`, `MorkeTunnelNetHelpers.c` | `MorkeTunnel/`, with its headers and bridging header |
| `main.swift` | `MorkeTunnelMac/`, the host above |

`MorkeTunnel/TunnelAnalytics.swift` is the iOS extension's alone. The target
bundles no resources.

| Link | Kind |
|---|---|
| `Libbox.xcframework` | vendored, built in § 2 above (the `macos-arm64_x86_64` slice, a static `ar` archive) |
| `MorkeShared` | the SwiftPM module in this repository |
| `NetworkExtension.framework`, `SystemConfiguration.framework`, `Cocoa.framework`, `Carbon.framework`, `CoreText.framework`, `UniformTypeIdentifiers.framework` | system |
| `libresolv.tbd`, `libbsm.tbd` | system |

### macOS bundle configuration

`macOS/MorkeTunnel-macOS-Info.plist` (checked in, not generated):

```xml
<key>CFBundlePackageType</key>       <string>SYSX</string>
<key>NetworkExtension</key>
<dict>
  <key>NEMachServiceName</key>       <string>$(MORKE_APP_GROUP).tunnel</string>
  <key>NEProviderClasses</key>
  <dict>
    <key>com.apple.networkextension.packet-tunnel</key>
    <string>PacketTunnelProvider</string>
  </dict>
</dict>
```

`MorkeTunnel-macOS.entitlements`:

```
com.apple.developer.networking.networkextension = [$(MORKE_NE_PROVIDER)]
com.apple.security.app-sandbox                  = true
com.apple.security.application-groups           = [$(MORKE_APP_GROUP)]
com.apple.security.network.client               = true
com.apple.security.network.server               = true
keychain-access-groups                          = [$(AppIdentifierPrefix)$(MORKE_KEYCHAIN_GROUP)]
```

### The behavioural split

The one behavioural difference the sources encode is that the macOS system
extension runs sandboxed **as root**, in the system context, where neither the
user's data-protection keychain nor the login keychain is reachable (so it makes
no `SecItem` call at all) and the App Group container it reaches is root's. So on
macOS the tunnel configuration never travels in `providerConfiguration`, whose
store every local account can read: the app puts it over the extension's XPC
service (the host above), and the extension keeps it in a `0600` cache in its own
container. On iOS it lives in the shared Keychain. On both, `providerConfiguration`
carries only a non-secret flag. `AppGroup`, `SharedKeychain`, `TunnelConfigCache`,
`TunnelControl`, `PacketTunnelProvider` and `main.swift` carry that split.

---

## 5. What is deliberately absent

This repository contains no network client. The extension's own code — every
file in `MorkeTunnel/` and `MorkeShared/` — has no `URLSession`, no API base URL
and no credential of its own; it reads a configuration the app placed for it and
hands it to libbox.

The engine is a different matter, and it is said plainly here because an earlier
version of this file got it wrong. sing-box carries an HTTP client of its own for
downloading remote rule-sets, and besides its default Go implementation that
includes one built on `NSURLSession` (sing-box's `apple` HTTP engine) — so the
shipped binary **does** reference `NSURLSession`, and has since `v1.13.13`. Neither
is a control-plane client: they fetch only what a configuration names, and the
configurations this app hands over select neither engine explicitly, which leaves
Go's. See [README.md § Provenance](README.md#provenance-and-what-it-does-not-prove).
