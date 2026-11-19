# Export manifest

The definitive statement of what this repository contains, why each file is in
it, and how to regenerate it from the Morke source tree deterministically.

Two audiences. If you received this repository, it tells you the source set is
complete and lets you verify it. If you maintain it, it is the rule that decides
whether a new file belongs here — and the rule matters more than the list below,
because the list changes.

---

## The membership rule

> A file belongs in this repository **if and only if** it is either
>
> **(1)** compiled or linked into `MorkeTunnel.appex`, or
> **(2)** required to generate, install or run that object code — bundle
> configuration, entitlements, privacy manifest, and the build recipe and
> settings.
>
> Nothing else. Not proximity in the source tree, not shared authorship, not
> "it seemed related".

Limb (1) is GPLv3 § 5(c): *"You must license the entire work, as a whole, under
this License to anyone who comes into possession of a copy … regardless of how
they are packaged."* Applied to a static link, that reaches everything compiled
into the extension.

Limb (2) is GPLv3 § 1: Corresponding Source is *"all the source code needed to
generate, install, and … run the object code and to modify the work, including
scripts to control those activities."* A privacy manifest and an entitlements
file are not source code in the everyday sense, but without them the object code
cannot be generated or installed, so they are inside the definition.

**Applying the rule when something changes:**

- A new file in `MorkeTunnel/` → in, automatically. That directory is a
  file-system-synchronized Xcode group: every file added to it joins the iOS
  extension target without anyone editing the project. ⚠️ The macOS system-extension
  target (`MorkeTunnel (macOS)`) lists its sources explicitly in the project file —
  a new file joins it only when added there (found by P9g, 2026-10-06). Either way
  the file is in: it is compiled into the iOS extension.
- A new file in `MorkeShared/` → in. The whole module is linked.
- A new module linked by the extension → the whole module joins the perimeter,
  and its own licence position has to be settled before it does. Adding one is
  also constrained independently: the extension's link set is a Packet-Tunnel
  memory budget, not a module boundary.
- A file that the app links but the extension does not → **out**. That is the
  entire closed half of the tree and it stays closed.
- Renaming or moving a file inside the perimeter → still in; update the list.

---

## Resolved list — 2026-11-19

Left column is the path **in this repository**. `MorkeShared/` is published flat;
in the Morke tree it lives at `MorkeKit/Sources/MorkeShared/`. Nothing else is
remapped.

**33 files in all:** 20 in block A, 3 in B, 2 in C and 8 in D (`singbox-fork/licences.py` joined D on 2026-09-23, P3;
`MorkeTunnel/TunnelAnalytics.swift` and five `MorkeShared/` files joined A between 2026-10-06 and 2026-11-17).

### A. Compiled into the extension — GPLv3 § 5(c)

| Published path | SHA-256 | Lines |
|---|---|---|
| `MorkeTunnel/PacketTunnelProvider.swift` | `b00b958f…c42931` | 605 |
| `MorkeTunnel/SingBoxTunnel.swift` | `03b383a8…bb5b75` | 323 |
| `MorkeTunnel/TunnelAnalytics.swift` | `707b5ce5…a1f28e` | 396 |
| `MorkeTunnel/ExtensionPlatformInterface.m` | `290b66ac…1520db` | 751 |
| `MorkeTunnel/ExtensionPlatformInterface.h` | `8b747882…9af9fb` | 61 |
| `MorkeTunnel/MorkeTunnelNetHelpers.c` | `dd32bae6…326033` | 140 |
| `MorkeTunnel/MorkeTunnelNetHelpers.h` | `b5326097…d7e315` | 106 |
| `MorkeTunnel/MorkeTunnel-Bridging-Header.h` | `f6a7ac93…90f734` | 29 |
| `MorkeShared/AnalyticsLedger.swift` | `6e2cd1dd…b7e433` | 961 |
| `MorkeShared/AppGroup.swift` | `b5e22810…fa5e53` | 694 |
| `MorkeShared/MorkeLog.swift` | `0af77295…929a5d` | 58 |
| `MorkeShared/SharedKeychain.swift` | `6b10893f…70804d` | 349 |
| `MorkeShared/SingBoxConfig.swift` | `57768dcf…af1ca0` | 56 |
| `MorkeShared/SingBoxConfigStrip.swift` | `4aae4280…da58e6` | 159 |
| `MorkeShared/SingBoxGVisorStack.swift` | `fa784ece…b5dbd2` | 106 |
| `MorkeShared/TunnelConfigCache.swift` | `db0c056e…5ca9fb` | 524 |
| `MorkeShared/TunnelControl.swift` | `37733840…2d5279` | 394 |
| `MorkeShared/TunnelDiagnostics.swift` | `703a1a96…2b663b` | 198 |
| `MorkeShared/TunnelExtensionConstants.swift` | `46fa2095…cdcd02` | 66 |
| `MorkeShared/VPNSurfaceState.swift` | `129e9210…9512b7` | 237 |

**20 files, 6 213 lines.**

> **On that number.** The perimeter was measured at **2 079 lines** on
> 2026-09-04 *before* the GPLv3 § 5(b) notices were written into these files;
> that figure is re-measured here and confirmed exactly. Adding the notices —
> 25 lines to each of the 7 tunnel files, 40 to each of the 6 `MorkeShared`
> files — took it to **2 494**. Both numbers are correct for their moment;
> neither supersedes the other. Quote 2 079 when talking about the size of the
> code, 2 494 when talking about the size of the files.
>
> **Re-measured 2026-09-11: 14 files, 3 002 lines.** That is the 2 494 above plus
> 508 — `VPNSurfaceState.swift` is new (235 lines, with the same 40-line notice as
> its neighbours), `AppGroup.swift` grew by 161, `PacketTunnelProvider.swift` by
> 109 and `SharedKeychain.swift` by 3. No existing notice changed, so the code
> without notices is 3 002 − (7 × 25 + 7 × 40) = **2 547** lines. For this
> snapshot quote 2 547 for the code and 3 002 for the files; the 2026-09-04 pair
> stays correct for its moment.
>
> **Re-measured 2026-09-23: 14 files, 3 033 lines.** That is 3 002 plus 31 —
> `ExtensionPlatformInterface.m` grew by 21 (the three platform-interface methods
> libbox `v1.14` added, and one it dropped) and `TunnelDiagnostics.swift` by 10 (a
> change made after 2026-09-11 that this list had not yet recorded). No notice
> changed, so the code without notices is 3 033 − 455 = **2 578** lines.
>
> **Re-measured 2026-10-04: 14 files, 3 062 lines.** That is 3 033 plus 29 —
> `SingBoxTunnel.swift` grew by 29 (T-CFG-67: it deletes the plaintext
> `configuration.json` an earlier engine left, before the engine starts). No notice
> changed, so the code without notices is 3 062 − 455 = **2 607** lines.
>
> **Re-measured 2026-11-19: 20 files, 6 213 lines.** That is 3 062 plus 3 151. Six files are new,
> 2 540 lines between them: `MorkeTunnel/TunnelAnalytics.swift` (396, the 25-line tunnel notice) and,
> each with the 40-line `MorkeShared` notice, `AnalyticsLedger.swift` (961), `SingBoxConfigStrip.swift`
> (159), `SingBoxGVisorStack.swift` (106), `TunnelConfigCache.swift` (524) and `TunnelControl.swift`
> (394). The fourteen already listed grew by 611 net: `AppGroup.swift` +299, `PacketTunnelProvider.swift`
> +141, `SingBoxTunnel.swift` +91, `MorkeTunnelNetHelpers.c` +24, `SharedKeychain.swift` +17,
> `MorkeTunnelNetHelpers.h` +15, `TunnelDiagnostics.swift` +14, `TunnelExtensionConstants.swift` +7,
> `ExtensionPlatformInterface.h` +4, `VPNSurfaceState.swift` +2, `SingBoxConfig.swift` +1,
> `MorkeLog.swift` −1, `ExtensionPlatformInterface.m` −3, the bridging header unchanged. Every file
> still carries its notice (the SPDX check in the release checklist, step 3), so the notices are
> 8 × 25 + 12 × 40 = 680 lines and the code without them is 6 213 − 680 = **5 533** lines.

**One system framework joined the extension's links, and the rule adds no file
for it.** `PacketTunnelProvider.swift` now imports Apple's `WidgetKit`, so that a
stopped tunnel refreshes the Morke app's Home Screen widget and Control Center
control. `WidgetKit.framework` ships with iOS: it is not source in this
repository and not code we convey, and GPLv3 § 1 says Corresponding Source "does
not include the work's System Libraries" — the footing `NetworkExtension`,
`UIKit` and `Foundation` were already on. The rule's *new module* clause is about
code compiled into the extension from source, and none was added: the extension
still links `MorkeShared` and `Libbox.xcframework` and nothing else of ours.
[BUILD.md](BUILD.md) § 3 lists `WidgetKit` with the other system links.

### B. Build inputs — GPLv3 § 1, required for the shipped iOS extension

| Published path | SHA-256 | Lines |
|---|---|---|
| `MorkeTunnel/Info.plist` | `c63f1779…35fa02` | 31 |
| `MorkeTunnel/MorkeTunnel.entitlements` | `9f4f660b…28e1ec` | 18 |
| `MorkeTunnel/PrivacyInfo.xcprivacy` | `232448fd…7d4f91` | 95 |

These three are in the perimeter under limb (2) of the rule, and this is a
reading, not a copy of somebody's list: without the `Info.plist` there is no
`CFBundlePackageType = XPC!` and the extension will not launch; without the
entitlements it cannot claim the packet-tunnel provider point or reach its App
Group. They are required to generate and install the object code, so § 1 reaches
them. They contain no secret.

The complete build-settings table is in [BUILD.md](BUILD.md) § 3 rather than in a
project file, because the Xcode project also configures targets this licence does
not cover. That is the one place where a strict reader could ask for more; the
settings themselves are reproduced verbatim, which is the substance of what § 1
asks for.

### C. macOS build inputs — included, not yet owed

| Published path | SHA-256 | Lines |
|---|---|---|
| `MorkeTunnel/MorkeTunnel-macOS.entitlements` | `b523c86f…560ac3` | 31 |
| `macOS/MorkeTunnel-macOS-Info.plist` | `546d442b…614215` | 57 |

The same sources also build a macOS **system extension**. That build is not
conveyed today — only the iOS application ships — so these two are not yet owed
under § 6. They are published anyway, because the sources here already encode the
macOS behavioural split and withholding the two files that make it buildable
would leave the recipient with source that does not build for a platform it
plainly supports. In the Morke tree the second file lives at
`Config/MorkeTunnel-macOS-Info.plist`; `Config/` also holds the closed app's own
build configuration, so only that one file is exported and it is remapped to
`macOS/`.

**When the macOS application is conveyed, these move to block B and the
`MorkeTunnel (macOS)` target's build settings must be added to BUILD.md § 4.**
That is the one foreseeable change to this manifest that is an obligation rather
than tidiness.

### D. Authored for this repository

`LICENSE` · `COPYING-SCOPE.md` · `README.md` · `BUILD.md` · `MANIFEST.md` ·
`singbox-fork/0001-morke-trim.patch` · `singbox-fork/libbox-digest.py` · `singbox-fork/licences.py`

Not exported from the Morke tree; written for publication. `LICENSE` is the
verbatim GNU GPL v3 text and **nothing else** — the scope notice that used to
precede it moved to `COPYING-SCOPE.md` on 2026-09-05, because a preamble in front
of the text defeats automatic licence detection. The file is byte-identical to
the copy the application ships in **Settings → About → Legal → Licences**,
which is checkable, and the digest is unchanged by the move because only the
preamble was removed:

```sh
shasum -a 256 LICENSE
# 8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903
```

**`singbox-fork/` is a GPLv3 § 1 obligation, not a convenience.** From
2026-09-04 the extension links a **modified** sing-box, so the Corresponding
Source is our modified tree — not upstream's tag. The patch is that
modification, expressed against the upstream commit so it can be reviewed in one
sitting rather than as a re-published 8 MB tree, and applying it to
`c005f35300ce76427dc285481ec5695f5b179cd2` (tag `v1.14.4`) reproduces our engine
source exactly (re-derived 2026-11-14; the `v1.14.1` base it replaces was
`1ac1a339cb1223e9c70eae14c44411c75033c02d`).

| File | SHA-256 |
|---|---|
| `singbox-fork/0001-morke-trim.patch` | `ded97a1e8e4195e330ff71c0140367d26a9369ce31861cb03758644b98c76486` |
| `singbox-fork/libbox-digest.py` | `7b14008f591df315c857adf3f2a55718ea679d96a1c016059d47e74f602167ff` |
| `singbox-fork/licences.py` | `af75330f38dfd05dcd0f98a69defb1297ccff391168834319a395e3003421f8c` |

`libbox-digest.py` is the checker for [BUILD.md § 2.3](BUILD.md); it is stdlib
only, makes no network call and writes nothing.

### E. Excluded, deliberately

| Not published | Why |
|---|---|
| `Morke.xcodeproj/` | configures targets outside the perimeter; the covered target's settings are reproduced verbatim in BUILD.md instead |
| `Frameworks/Libbox.xcframework` | a build product, not source. Rebuild it from commit `c005f353…` (tag `v1.14.4`) **plus `singbox-fork/0001-morke-trim.patch`** by BUILD.md § 2, and check it against the digests in § 2.3 |
| `MorkeKit/Sources/{MorkeFeatures,MorkeServices,MorkeModels,MorkeDesignSystem,PlatformKit}` | linked by the app, never by the extension |
| `MorkeTunnelMac/main.swift` | the macOS system-extension executable host; not compiled into the iOS appex |
| `MorkeTunnelTests/`, every other test target | not compiled into the extension |
| `Config/Debug.xcconfig`, `Config/Release.xcconfig` | the app's configuration, and gitignored locally |
| `.DS_Store` | Finder metadata. Present in `MorkeTunnel/` on macOS; it is not source and must not be exported |
| `Docs/`, `store/`, `scripts/` | internal working documents and tooling |

---

## Verifying this repository

Every file in blocks A–C, in one command from the repository root:

```sh
find MorkeTunnel MorkeShared macOS singbox-fork -type f ! -name '.DS_Store' -print0 \
  | LC_ALL=C sort -z | xargs -0 shasum -a 256
```

Compare against the tables above. A digest that does not match means the file
changed after this manifest was written — which is the point of recording them.
They date the snapshot; they are a change detector, not a promise about any
binary. What the digests **cannot** tell you is whether this source built the
`.ipa` you downloaded: see [README.md § Provenance](README.md#provenance-and-what-it-does-not-prove).

## Regenerating this repository from the Morke tree

Run from the root of the Morke source tree, with `$OUT` an empty directory:

```sh
mkdir -p "$OUT/MorkeTunnel" "$OUT/MorkeShared" "$OUT/macOS"

# A + B + C — everything in MorkeTunnel/ except Finder metadata
find MorkeTunnel -type f ! -name '.DS_Store' -exec cp {} "$OUT/MorkeTunnel/" \;

# A — the shared module, published flat
cp MorkeKit/Sources/MorkeShared/*.swift "$OUT/MorkeShared/"

# C — the one macOS build input that lives outside MorkeTunnel/
cp Config/MorkeTunnel-macOS-Info.plist "$OUT/macOS/"

# D — the authored files
cp publish/tunnel-source/{LICENSE,COPYING-SCOPE.md,README.md,BUILD.md,MANIFEST.md} "$OUT/"
cp -R publish/tunnel-source/singbox-fork "$OUT/"
```

The first `find` is the rule expressed as a command: `MorkeTunnel/` is a
file-system-synchronized Xcode group, so its contents and the iOS target's contents
are the same set by construction (the macOS target compiles a subset of it). That is why the export is a directory copy and
not a hand-kept file list — a hand-kept list is what goes stale.

**Then, before publishing, re-run the safety sweep.** It is not a formality; it
is what stands between this repository and a leaked credential:

```sh
grep -rniE 'api\.morkenet|morkenet\.com|https?://|apiKey|secret|password|token' "$OUT"
grep -rn 'URLSession' "$OUT"
```

Expected on 2026-09-23, and read again on 2026-11-19 with the same result: no live secret, no API base URL, and no `URLSession` in
any source file — the extension makes no control-plane call at all; the only
`URLSession` matches are sentences in this repository's documents and in
`PrivacyInfo.xcprivacy` saying so. The `https://`
matches are Apple's plist DTD declarations, links in comments, and the GPL's own
`gnu.org` URL. One real identifier is present and is published knowingly: the
Apple Team ID `VM3XX8889Q`, in `MorkeShared/SharedKeychain.swift`, as a
documented fallback Keychain access-group prefix, and since 2026-11-17 in
`MorkeShared/TunnelControl.swift` as `teamIdentifier`, the team the Mac extension's
code-signing requirement names (and in `BUILD.md` as `DEVELOPMENT_TEAM`). See
[README.md § A note on the Apple Team ID](README.md#a-note-on-the-apple-team-id).
