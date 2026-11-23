# Morke tunnel — Corresponding Source

This repository is the **Corresponding Source** (GNU GPL v3 § 1) for the Morke
tunnel extension: `MorkeTunnel.appex`, the Network Extension inside the Morke VPN
application for iOS, and `tech.twodice.morke.tunnel.systemextension`, the system
extension inside the Morke VPN application for macOS. Both applications ship: the
iOS one through the App Store, the macOS one by direct download since 27.0.0 (4),
2026-11-17.

It exists because the extension statically links
[sing-box](https://github.com/SagerNet/sing-box), which is licensed
GPL-3.0-or-later. Shipping that, in either application, is **conveying**, and GPLv3
§ 5(c) requires the entire extension, as a whole, to be licensed under the same
terms to anyone who comes into possession of a copy. § 6 then requires us to
offer the source. This is that offer, discharged by publication.

**Pinned engine: sing-box `v1.14.4`, modified.** We do not ship upstream's build.
The engine is trimmed to the protocols this client can actually reach, and the
modification is published here as a 568-line patch over eleven files against
upstream commit `c005f35300ce76427dc285481ec5695f5b179cd2` — see
[`singbox-fork/`](singbox-fork/) and [BUILD.md § 1](BUILD.md). GPLv3 § 5(a)
requires us to say that the work is modified and to date it; those dates are
**2026-09-23**, **2026-10-04** and **2026-11-14**, and every file the patch touches carries the
notice in its own header. (The engine was first modified on 2026-09-04, on top of `v1.13.13`; this
patch replaces that one.)

**Licence: GNU GPL v3 or later.** The text is [`LICENSE`](LICENSE), verbatim and
unmodified. What it covers, what it deliberately does *not* reach, the one module
that is dual-licensed, and why an automatic detector may label this repository
`GPL-3.0-only` when our position is `-or-later` — all of that is in
[**`COPYING-SCOPE.md`**](COPYING-SCOPE.md). **Read it before the licence itself.**

---

## What is here

| Path | What it is |
|---|---|
| `MorkeTunnel/PacketTunnelProvider.swift` | the `NEPacketTunnelProvider` subclass — start/stop/sleep/wake, on-demand handling, configuration read |
| `MorkeTunnel/SingBoxTunnel.swift` | the libbox engine wrapper: `LibboxCommandServer` setup → start → stop |
| `MorkeTunnel/ExtensionPlatformInterface.m/.h` | the Objective-C bridge implementing `LibboxPlatformInterface` and `LibboxCommandServerHandler` — TUN file-descriptor handover, interface enumeration, default-route monitoring, socket binding |
| `MorkeTunnel/MorkeTunnelNetHelpers.c/.h` | pure-C address and interface-classification helpers, split out so they can be unit-tested off-device |
| `MorkeTunnel/MorkeTunnel-Bridging-Header.h` | Swift ↔ Objective-C bridging header |
| `MorkeTunnel/Info.plist`, `*.entitlements`, `PrivacyInfo.xcprivacy` | the bundle configuration and build inputs needed to generate and install the extension |
| `MorkeTunnelMac/main.swift` | the macOS system extension's executable host: it starts NetworkExtension's system-extension mode and the XPC service the Mac app reaches the extension through |
| `macOS/MorkeTunnel-macOS-Info.plist` | the macOS system extension's bundle configuration |
| `MorkeShared/` | the app↔extension surface module the extension links: App Group keys, shared-Keychain accessors, the opaque configuration wrapper, the `os_log` subsystem, the diagnostics wire types |
| `LICENSE` | the GNU GPL v3 text, verbatim and alone — nothing added before or after it |
| `COPYING-SCOPE.md` | what that licence covers and what it does not: the perimeter, the dual-licensed module, the sing-box naming term, and the `-only` / `-or-later` label question |
| `BUILD.md` | how to build libbox from the pinned tag **plus our patch**, how to verify the result to the byte, and the extension's complete build configuration |
| `MANIFEST.md` | the rule that decides what belongs in this repository, and the resolved file list with digests |
| `singbox-fork/` | our modification to sing-box, as a patch against the upstream tag, plus the digest checker BUILD.md § 2.3 uses |

## What is *not* here, and why

This is the tunnel extension, not the product. Deliberately absent, because none
of it is compiled into the extension and none of it is therefore covered by
§ 5(c):

- the iOS and macOS client applications, their UI and their state management;
- authentication, the paywall and StoreKit purchase handling, App Attest,
  TLS public-key pinning, device-session management, the entitlement gate;
- the server node list, the routing logic and every piece of backend knowledge;
- the Morke backend service itself;
- the Morke name, logo, icons and artwork, which are trademarks and are not
  licensed by `LICENSE` or by [`COPYING-SCOPE.md`](COPYING-SCOPE.md) at all.

**The copyleft boundary is set by linking, not by repository layout.** This
repository exists to make § 6 satisfiable and § 5(c) legible. Splitting the
source did not create the boundary and does not move it.

### One module is dual-licensed

`MorkeShared/` is our own code and is linked by **both** binaries — this GPL
extension and the closed-source client. As the copyright holder we license it
twice: to you under the GPL, unconditionally, and to ourselves under our own
terms for the closed half. The first grant is not narrowed by the second. Every
file in `MorkeShared/` says so in its own header, and
[`COPYING-SCOPE.md`](COPYING-SCOPE.md) says so again.

## Reading the comments

The comments here refer to things you cannot see: task identifiers like
`T-CFG-41` or `B-SAFE-3`, and documents like `singbox-integration.md` or
`smoke-test.md` that live in the closed Morke tree. Those references dangle, and
that is deliberate.

They are left intact because GPLv3 § 1 asks for *"the preferred form of the work
for making modifications"*, and in this code the reasoning **is** the value — why
`ENABLE_DEBUG_DYLIB` must be `NO`, why nothing touches libbox during class
initialisation, why the configuration lives in the Keychain on iOS and in the
system extension's own root-only cache on macOS, what the IPv6 leak block is defending against.
Editing that out to tidy the presentation would hand you a worse artefact than
the one we build from, and would make the published source diverge from the
shipped source. Treat an unresolvable identifier as a bookmark for a decision
that was made and recorded, not as a missing file.

## Component licences

The engine this extension links is not one project. The significant set, each
read at the pinned tag or at the linked module's own `LICENSE`:

| Component | Licence | In the trimmed build? |
|---|---|---|
| `sagernet/sing-box`, `sing`, `sing-tun`, `sing-vmess`, `sing-mux`, `sing-snell` | GPL-3.0-or-later, plus a naming clause | linked |
| `sagernet/sing-quic`, `sing-shadowsocks`, `sing-shadowsocks2`, `sing-shadowtls`, `cronet-go` | GPL-3.0-or-later, plus a naming clause | not linked |
| `anytls/sing-anytls` | GPL-3.0-or-later | not linked |
| `sagernet/gvisor` | Apache-2.0 | linked |
| `sagernet/smux` | MIT | linked |
| `sagernet/quic-go`, `sagernet/wireguard-go` | MIT | not linked |
| `metacubex/utls`, `sagernet/gomobile` | BSD-3-Clause | linked |
| `sagernet/tailscale` | BSD-3-Clause | not linked (iOS since `v1.14.1-morke.1`, macOS since `v1.14.4-morke.1`) |

The right-hand column is a fact about *this* build, measured on the `ios-arm64`
and `macos-arm64_x86_64` slices as occurrences of each module's import path and as
defined symbols: zero means the module is not in the binary. Since `v1.14.4-morke.1`
the two slices link the same 40 modules. It is **not** a licence claim. The in-app
list is generated from the same linked set (`singbox-fork/licences.py`), so a
component marked *not linked* is not on it. Listing a notice for code that is not present costs a reader nothing;
the error § 4 does not forgive is the opposite one, a linked component with no
notice.

The sing-box licence appends a term we reproduce because § 4 requires notices to
be kept intact: *"no derivative work may use the name or imply association with
this application without prior consent."* It is a § 7(e)-style declining of
trademark rights and it restricts none of the freedoms the GPL grants.

The full texts of all of these are also reproduced inside the shipped
application, under **Settings → About → Legal → Licences**, so that a
recipient who never visits this repository still receives them.

## Provenance, and what it does not prove

Each App Store submission and each Mac release tags this repository with the
exact `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` of the build, as
`v<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>`, so the § 6(d) directions next to
the object code resolve to the source that produced it. The two platforms share
one build counter, so every tag names one build. `BUILD.md` records the sing-box
pin and the complete build configuration of both targets.

**That is provenance. It is not proof of build equivalence, and no such proof is
offered here.** Building this source will not reproduce the shipped binary
bit-for-bit, and we do not claim it will. On iOS, Apple re-signs and encrypts the
binary it delivers; on both platforms, Swift and Xcode builds are not
bit-reproducible in the first place. Anyone telling you a published source tree
proves what is in a downloaded `.ipa` or Mac app is overstating it.

What *can* be checked independently, and is worth more than a promise:

1. **The libbox artefact, and this one is exact.** Fetch commit
   `c005f35300ce76427dc285481ec5695f5b179cd2` (tag `v1.14.4`), apply
   `singbox-fork/0001-morke-trim.patch`, build by the recipe in `BUILD.md § 2`,
   and run `singbox-fork/libbox-digest.py` over the result. It should print the
   digests in `BUILD.md § 2.3`, byte for byte. We have run that comparison across
   two builds from different directories with separate Go build caches: every
   object member of the `Libbox` static libraries came out **identical**, and
   the only differing bytes sat in each `ar` symbol index — the ASCII timestamp
   `libtool` stamps into its header, and the alignment pad after its last symbol
   name, which `libtool` leaves uninitialised. The digest script blanks the first
   and zeroes the second (BUILD.md § 2.3 dates that correction). So this is not a "should roughly match": the engine half
   of the GPL claim is verifiable to the byte, without depending on anything we
   assert.

   Note that **building the upstream tag alone will not match**, and must not:
   we ship a modified engine, the patch is the modification, and a digest that
   matched upstream would mean the patch had not been applied.
2. **The absence of a control-plane client in the extension.** The extension's
   own code contains no `URLSession` and no API base URL, and the shipped appex
   contains no API base URL either; it makes no control-plane call at all. The
   binary **does** reference `NSURLSession`: sing-box's own HTTP client for
   remote rule-sets includes an `NSURLSession`-based engine besides its default
   Go one (`BUILD.md § 5`). Our earlier wording, "contains no `URLSession`", was
   true of our source and not of the binary. The data position is recorded in
   `MorkeTunnel/PrivacyInfo.xcprivacy`.

## A note on the Apple Team ID

The literal Team ID `VM3XX8889Q` appears in two source files.
`MorkeShared/SharedKeychain.swift` holds it as a documented fallback Keychain
access-group prefix, used only when the runtime value cannot be resolved, and
`MorkeShared/TunnelControl.swift` holds it as `teamIdentifier`, the team the macOS
system extension's code-signing requirement names when it accepts a connection
from the app. It is published knowingly. It is not a secret: it is recoverable
from any signed Apple binary and from the provisioning profile, and it authorises
nothing on its own. If you rebuild this extension under your own signing
identity, those two constants and the bundle identifiers in `BUILD.md` are what
you change.

## Contributing — pull requests are not the route here

**This repository is a publication target, not a development repository.** It is
regenerated by export from the closed Morke tree at every release, so anything
merged here would be silently overwritten by the next export. That is why pull
requests are closed: not to keep you out, but because merging one would quietly
lose your work.

**Open an issue instead.** A patch, a diff or a plain description in an issue is
welcome and is the form we can actually act on — we apply it upstream, and it
reaches you in the next release's export with your authorship recorded there.

One thing to know before you write a patch, because it cannot be repaired
afterwards:

- **`MorkeTunnel/` — ordinary GPL.** These files exist only inside the GPL
  extension. A change here is simply GPL code in a GPL work.
- **`MorkeShared/` — needs a copyright assignment or an explicit dual-licence
  grant.** This module is dual-licensed *only because a single party holds all of
  its copyright*. Someone else's GPL-licensed code landing in it could no longer
  ship inside the closed client, and the dual position `LICENSE` describes would
  quietly become false. Better said before you write it than after.

Your GPL rights do not depend on any of this. § 6 gives you the source and § 2
lets you fork and modify it however you like; the paragraphs above are about what
we can take *back* upstream, not about what you may do.

Support questions about the Morke application belong with the application, not
with this repository.
