// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Two Dice Ltd
//
// DUAL-LICENSED — this is our own code and it ships inside two different works.
// Both paragraphs are true at once; neither alone is the position.
//
//   • In MorkeTunnel.appex, which statically links sing-box
//     (https://github.com/SagerNet/sing-box, GPL-3.0-or-later), GPLv3 § 5(c)
//     licenses that entire work as a whole under the GPL. Everyone who receives
//     this file — from the shipped extension, or from the published tunnel-source
//     repository — receives it under the GNU General Public License v3 or later,
//     on the terms below. That grant is unconditional and nothing in this header
//     narrows it.
//
//   • In Morke.app, the closed-source client, which links no GPL-licensed code.
//     As the copyright holder we additionally license this same file under our own
//     proprietary terms for that use. Nothing here places Morke.app, or any other
//     MorkeKit module, under the GPL.
//
// Dual-licensing our own code is ordinary and deliberate, and it does not take back
// the grant above: a recipient may use this file under the GPL for anything the GPL
// allows. A blanket "this file is GPLv3" would be inaccurate in the other direction,
// and a blanket "this file is proprietary" would be inaccurate in this one.
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
// PARTICULAR PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along with
// this program. If not, see <https://www.gnu.org/licenses/>.
//
// Corresponding Source (GPLv3 § 6) and the build recipe that produced the object
// code: README.md and BUILD.md in the repository this file is published from.

import Foundation
#if os(iOS)
// SHA-256 for the iOS key fingerprint (T-CFG-45) and the refused rule-set digests (T-ROUTE-8) below.
// A SYSTEM framework, so MorkeShared stays package-dependency-free (Package.swift) and the NE memory
// budget is unaffected. Scoped to iOS so the macOS build links exactly what it linked before.
import CryptoKit
#endif

public nonisolated enum AppGroup {
    // P75: a Mac Debug build is its own app, "Morke Dev" (tech.twodice.morke.dev), beside the Release
    // Morke, so its sign-in, key and analytics never touch the installed one. Chosen at COMPILE time:
    // SwiftPM defines DEBUG for this package when Xcode builds the Debug configuration, so the app and
    // the system extension agree without reading anything at runtime, and there is no fallback that
    // could put a Dev build on the Release group. The entitlements and the extension's NEMachServiceName
    // take the same value from the MORKE_APP_GROUP build setting (project.pbxproj); the two move
    // together. iOS has no Dev variant (T-INFRA-38's ruling stands there): it always reads Release's.
    #if os(macOS) && DEBUG
    public static let appGroupID = "group.tech.twodice.morke.dev"
    #else
    public static let appGroupID = "group.tech.twodice.morke"
    #endif
    // The providerConfiguration key the config bytes were saved under. WRITTEN BY NOTHING ANY MORE: iOS
    // moved the bytes to the Keychain (T-CFG-41, see iOSConfigInKeychainKey below), and macOS out of the
    // profile into the extension's root-only cache (T-MAC-26, TunnelConfigCache), because the NE store
    // /Library/Preferences/com.apple.networkextension.plist is root:wheel 0644 — readable by every local
    // account (T-MAC-20). The name stays for the readers left: the macOS launch strip, which removes it from
    // a profile an earlier build saved (VPNCore.disarmOnDemand), the fallback strip after a failed removal,
    // and the tests that hold that neither platform's gate reads it.
    public static let singBoxConfigKey = "singBoxConfigJSON"

    // WHY THE MAC'S APP AND EXTENSION SHARE NO STORE (T-MAC-14, corrected on device 2026-08-04). The macOS
    // system extension runs SANDBOXED AND AS ROOT, in the system context rather than the user session, so
    // BOTH shared stores the iOS appex relies on are unreachable from it:
    //   • the user keychain — the extension makes no SecItem call on macOS (TN3137: a process outside a
    //     user context sees only the System keychain); and
    //   • the App-Group container — containerURL(forSecurityApplicationGroupIdentifier:) resolves PER
    //     USER, so the app (console user) gets ~/Library/Group Containers/<appGroupID>/ while the
    //     extension gets /var/root/Library/Group Containers/…. Neither process can see what the other
    //     writes. Do NOT use that container as an app↔sysext channel on macOS.
    // The channel is the extension's XPC service since T-MAC-26h (TunnelControl), which is how Apple's DTS
    // says a system extension and its app talk.
    //
    // This key is the profile's "user is authenticated" flag that T-MAC-14 to T-MAC-26g's startTunnel guarded
    // on. WRITTEN AND READ BY NOTHING ANY MORE (T-MAC-26h, P84 point 4: the profile carries no account state;
    // a start runs the cache, which the revoke takes away). The name stays for the fallback strip after a
    // failed removal, which removes it from a profile an earlier build saved, and for the iOS test that holds
    // no Mac key opens the iOS gate.
    public static let macOSAuthenticatedKey = "macOSAuthenticated"

    // The profile's config generation, T-MAC-26 to T-MAC-26g's binding of the cache to a save. WRITTEN AND
    // READ BY NOTHING ANY MORE (T-MAC-26h): the start no longer authorises against the profile, whose view on
    // this macOS lags the app's saves (P78e/f/g), so the generation, T-MAC-26f's start token and its
    // `viewAgrees` went with the provider-message handover. The name stays for the same two readers as
    // macOSAuthenticatedKey above.
    public static let configGenerationKey = "configGeneration"

    // The generation a dictionary carries when it is a well-formed UUID string. nil for an absent key,
    // any other type, and a malformed string. Kept for the iOS test above (no Mac key opens its gate).
    public static func configGeneration(in dictionary: [String: Any]?) -> UUID? {
        (dictionary?[configGenerationKey] as? String).flatMap(UUID.init(uuidString:))
    }

    // Resolves the real App-Group container. nil when it can't be resolved (off-device / no
    // entitlement) — a nil container makes the gate helpers below read as NOT authorised
    // (FAIL-CLOSED). The public helpers take an INJECTABLE `container` seam (mirroring
    // TunnelWorkspace.wipe(container:)) and fall back to this when none is passed.
    //
    // Outside the `#if os(iOS)` block below on purpose (T-CFG-53). The iOS-only restriction was never
    // about resolving a container — it was about using one as an app↔EXTENSION channel, which on macOS
    // is impossible (containerURL resolves PER USER and the sysext runs as root; see
    // macOSAuthenticatedKey above). The re-arm intent below is written and read by the APP process only.
    // Module-internal (T-EXT-0) so the VPN-surface store in VPNSurfaceState.swift resolves the container
    // through the SAME function — one derivation, and one place where fail-closed on an unresolvable
    // container is decided. Not public: outside MorkeShared the container is reached only through the
    // helpers that already carry that discipline.
    static func defaultContainer() -> URL? {
        containerOverride ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    // TEST SEAM, and a `@TaskLocal` for a specific reason (T-EXT-1, 2026-09-08). The App-Group document
    // is process-global and every HomeFeature suite writes it as a side effect of reducing. Measured,
    // not feared: a suite that ASSERTS on the document failed when another suite published concurrently
    // (swift-testing parallelises within a target), and a plain test run rewrote the real widget's
    // state on the simulator or device it ran on. Per-case isolation, as T-QA-27 did for UserDefaults:
    // a `@TaskLocal` rather than a mutable static because parallel cases each need their own value — a
    // `static var` would be the very defect being fixed — and because it propagates into the child
    // tasks TCA effects run on, which is where the publish actually happens.
    //
    // `nil` in production, always: nothing in the app or the extension sets it, so `defaultContainer`
    // resolves exactly as it did before. It costs the appex one optional read per container lookup.
    // `public` because MorkeTests is an Xcode target outside this package, so `package` would not
    // reach it. It is a seam, not API: the same shape as the `container:` parameter every helper
    // below already exposes publicly for the same reason.
    @TaskLocal public static var containerOverride: URL?

    // MARK: - On-demand re-arm intent (T-CFG-53)
    //
    // WHAT IT RECORDS, and nothing else: "on-demand SHOULD be armed — the user's settings ask for it
    // — but the installed profile had no config the extension could start, so we took it away." It is
    // not a copy of the preference (AppSettings holds that) and not a record of the tunnel's state.
    //
    // WHY IT HAS TO EXIST. T-CFG-52's disarm of an armed-but-unstartable profile (what ends the restart
    // loop) is SILENT AND PERMANENT until the next Connect: with the kill switch on, the whole protection
    // is gone, nothing on screen says so, and the user did not cause it (an app update left the config
    // store stale). This marks "off BECAUSE it could not start", which the app may repair, apart from
    // "off because the user switched it off" — never conflate them: re-arming the second would override
    // a deliberate choice. Record and device evidence: Docs/reference/closed-work-cfg.md § T-CFG-53.
    //
    // LIFETIME is exactly right by construction. The App-Group container survives an app UPDATE — the
    // case this exists for — and is destroyed by an UNINSTALL, where a fresh install has no profile
    // and nothing to repair. Presence of the file IS the value: nothing to decode, no partial state,
    // no migration. Deliberately NOT the Keychain (it is not a secret) and NOT AppSettings (it is not
    // a user preference and must never surface as one, nor be exported/restored with them).

    private static let onDemandRearmPendingName = "on-demand-rearm-pending"

    // Best-effort on purpose (`try?`, no throw): a write that fails simply loses the intent and the
    // behaviour degrades to what it was before this existed — a disarm that waits for the user. The
    // opposite bias would be worse, and there is no caller that could act on the error.
    public static func setOnDemandRearmPending(_ pending: Bool, container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        let url = container.appendingPathComponent(onDemandRearmPendingName)
        if pending {
            try? Data().write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // An unresolvable container reads FALSE — no intent, no automatic connect. Same fail-closed bias
    // as the gate helpers below: the failure mode of a wrong `true` here is raising a tunnel nobody
    // asked for, which is strictly worse than not repairing one.
    public static func isOnDemandRearmPending(container: URL? = nil) -> Bool {
        guard let container = container ?? defaultContainer() else { return false }
        return FileManager.default.fileExists(
            atPath: container.appendingPathComponent(onDemandRearmPendingName).path
        )
    }

    // MARK: - Surface connect request (T-EXT-0)
    //
    // WHAT IT RECORDS: "the user asked for a connect from OUTSIDE the app, and it was not done there."
    // Set by the intent's two refusals whose documented repair is an in-app connect — no profile
    // installed, and no stored config (T-CFG-41) — and by the Home Screen quick action (T-EXT-2), which
    // records the ask without attempting it (VPNToggle.recordConnectRequest). Not `.notSignedIn` (they
    // land on the login screen, which is its own flow) and not `.busy` (nothing to repair).
    //
    // WHY IT EXISTS. Opening the app on Home is a truthful answer but a thin one: the user pressed a
    // control and the thing they pressed it for did not happen, with no route to the reason. It is
    // sharpest for an unsubscribed account, where the honest destination is the paywall — and the
    // intent CANNOT work that out for itself: it runs in a background app process where AuthSession
    // is empty by construction, so entitlement is unknowable there without a network round trip
    // inside a toggle. The app, once open, already knows: replaying the connect puts the user through
    // the SAME gates a Connect tap does, and those gates present the paywall. So this carries the
    // intent across the process boundary rather than duplicating a judgement in the wrong place.
    //
    // AT MOST ONCE, and consumed rather than read: the user asked once. Cleared by the consume, by a
    // failed silent re-login (no session, nothing to replay), and by TunnelWorkspace.wipe() on
    // sign-out — so a request can never outlive the account that made it.
    //
    // Same file-presence shape and the same best-effort bias as the re-arm intent above: presence IS
    // the value, an unresolvable container reads false, and a lost write costs one replay rather than
    // producing one nobody asked for.

    private static let pendingSurfaceConnectName = "surface-connect-pending"

    public static func setPendingSurfaceConnect(_ pending: Bool, container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        let url = container.appendingPathComponent(pendingSurfaceConnectName)
        if pending {
            try? Data().write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func isPendingSurfaceConnect(container: URL? = nil) -> Bool {
        guard let container = container ?? defaultContainer() else { return false }
        return FileManager.default.fileExists(
            atPath: container.appendingPathComponent(pendingSurfaceConnectName).path
        )
    }

    // MARK: - The engine's workspace (T-MAC-15)
    //
    // WHAT IT IS: everything sing-box keeps in an App-Group container where SingBoxTunnel.start points
    // it — basePath = the container, workingPath = Working/, tempPath = Library/Caches/. Measured in the
    // macOS extension's own container on 2026-10-17: Working/ held the stderr crash log libbox
    // redirects (CrashReport-.log), its OOM reports and a cache_file (cache.db) an earlier config had
    // enabled; the root held the configuration.json engines before 1.14.1-morke.2 wrote (T-CFG-67). A
    // cache.db at the root is where the iOS Smart merge points cache_file. libbox's command socket,
    // <container>/command.sock, is not on the list: the engine unlinks it when its listener closes
    // (absent from the same measurement, taken with the tunnel down).
    // Nothing on the list is read by a later session — the engine starts from the config in memory,
    // and the reports are for a host app that exports them, which this one never does.
    //
    // ONE LIST, TWO HANDS. TunnelWorkspace.wipe(container:) removes it on sign-out, Reset VPN profile
    // and account deletion — from the container the APP resolves, which on iOS is the one the appex
    // wrote. On macOS the system extension runs as root and writes into ROOT's container, which the
    // app never reaches (T-MAC-14), so the extension removes it itself, at the end of every stop and
    // before every start (SingBoxTunnel.scrubWorkspace).
    //
    // NOT on it, deliberately: the diagnostic event ring (its own entry point, T-INFRA-40(d)), the
    // surface state, the pending connect, the re-arm intent, the iOS fingerprint, the refused-list
    // marker (T-ROUTE-8), the analytics containers, the container's own system metadata, and the Mac's
    // config cache (TunnelConfigCache, T-MAC-26): it is what every start runs, so a stop
    // that removed it would leave the next on-demand or Kill Switch start nothing to start from.
    //
    // Best-effort and never throws: each item is removed on its own, an absent one is success, and the
    // result names each one that could not be removed — by its name in the list, with the POSIX errno
    // when the error carries one — so a caller logs a constant and a number, never anything read from
    // disk. Empty is success.
    @discardableResult
    public static func removeEngineWorkspace(in container: URL) -> [(item: String, errno: Int?)] {
        var failures: [(item: String, errno: Int?)] = []
        for item in ["Working", "Library/Caches", "cache.db", "configuration.json"] {
            do {
                try FileManager.default.removeItem(at: container.appendingPathComponent(item))
            } catch CocoaError.fileNoSuchFile {
                // Absent: nothing to remove.
            } catch {
                let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)
                    .flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
                failures.append((item, code))
            }
        }
        return failures
    }


    // MARK: - Protected time — the tunnel's analytics document, and the v1 totals it replaced (T-UX-7 → P9g)
    //
    // WHAT THE TUNNEL WRITES, since P9g: `analytics-tunnel.json` (AnalyticsLedger) — since P9h in the
    // session's account container, not at the App-Group root — through
    // `foldTunnelAnalytics` below — protected seconds per time bucket and per local day, bytes through
    // the tunnel per bucket, the starts that came up, and Kill Switch blocks. The line it is held to
    // is the one the maintainer restated on 2026-10-06, in ONE place: ConnectionMetricsClient.swift's
    // header, § THE PRIVACY LINE — counters, at most 64 bounded buckets that coarsen as history grows,
    // a ring of the last 90 local days, and still never a row per session, an event time, a node or a
    // reason. Read the line there, not a paraphrase here.
    //
    // WHY THE EXTENSION OWNS IT, and it is the only process that can. The app observes NEVPNStatus
    // only while it is running: a tunnel raised on demand and dropped hours later, with the app
    // suspended the whole time — which is the ordinary case for a VPN nobody has to think about —
    // is invisible to it. Only this process sees a session from start to stop.
    //
    // WHICH DOCUMENT (P9h): one per account, in that account's container (AnalyticsLedger § Containers).
    // The session's container is chosen ONCE, at the start that came up, from the pointer the app
    // writes — `tunnelAnalyticsDirectory` — and every write of that session goes there, so a session
    // is never split between two accounts. With no valid pointer the session writes `pending/`, which
    // the app adopts into the account that becomes current. This process creates no account's
    // directory: one that is missing (the account was deleted) only makes the write fail.
    //
    // ONE WRITER, AND THE APP IS THE ONE OTHER HAND ON THE FILE. The tunnel writes the document; the
    // app only reads it, and deletes it — its reset (ConnectionMetricsStore.reset), an account's
    // deletion (the whole container), and adoption (which moves `pending`'s away). So the tunnel never
    // holds the document across writes: it holds only what accrued since its last write, and every
    // write reads the file fresh, adds that, and replaces the file ONLY IF IT IS STILL THERE — nothing
    // but this process creates it, so "still there" is "still the one it read" (see
    // replaceTunnelDocument). In an account's container, a document this session already wrote and no
    // longer finds was reset, and what accrued meanwhile is DROPPED, not written into the new history —
    // the cost is at most the one interval since the last write. In `pending/` nothing resets: a
    // document gone from there was ADOPTED with everything up to the last write, so what accrued since
    // starts a new pending document instead (TunnelAnalyticsRecorder.write).
    //
    // WHAT THE NUMBER MEANS, exactly, so nothing over-claims: from the moment a start CAME UP
    // (`completion(nil)`) to the last write — a checkpoint every five minutes while up, one at sleep,
    // one at stop. A crash, a jetsam kill or a reboot now loses only the interval since the last write,
    // not the session. The total is a close lower bound, never an inflated one.
    //
    // ⚠️ The interval's LENGTH must come from a MONOTONIC clock, never from two `Date()` readings: a
    // wall-clock correction mid-session would otherwise fold a jump into a total the user can only fix
    // by resetting it. The wall clock only PLACES a measured length in buckets and days
    // (AnalyticsLedger.split). See MorkeTunnel/TunnelAnalytics.swift.
    //
    // THE v1 FILE, `protected-time-totals.json` — two integers, `sessions` and `seconds`, written by
    // builds before P9g and by nothing since — and the root `analytics-tunnel.json` builds before P9h
    // wrote: both sit at the App-Group container's ROOT, the pre-update history of whoever was signed
    // in. The APP adopts them into the first account container that becomes current
    // (ConnectionMetricsStore § Adoption); this process never reads the root again.
    //
    // NOT A SECRET, so the App-Group rule at the top of VPNSurfaceState.swift is satisfied by
    // construction: counters, bucket boundaries and day keys carry no destination, no address and no
    // credential. Nothing reads it but the app's own statistics — the widget and the Control Center
    // control do not, and must not start: what they render is the CURRENT connection, not a history.

    // The v1 shape. Never written since P9g; read by the app's adoption only.
    public struct ProtectedTimeTotals: Codable, Sendable, Equatable {
        // Sessions this device ran to a delivered stop. See the header for what it cannot count.
        public var sessions: Int
        // Their summed duration in whole seconds. Whole seconds because nothing on screen is finer
        // than a minute, and an Int cannot carry a fraction that hints at one session's exact length.
        public var seconds: Int

        public init(sessions: Int = 0, seconds: Int = 0) {
            self.sessions = sessions
            self.seconds = seconds
        }
    }

    // At the App-Group container's root. Public: the app's adoption reads it there, and the migration
    // suites write raw v1 fixtures under this name.
    public static let protectedTimeTotalsName = "protected-time-totals.json"

    // MARK: The tunnel's container (P9h)

    public struct TunnelAnalyticsDirectory: Equatable, Sendable {
        public var url: URL
        // `pending/`: no account was current when the session came up.
        public var isPending: Bool
    }

    // Resolved ONCE per session, at the start that came up. A path is built from a pointer only when
    // AnalyticsLedger.readPointer validated it as a container name; anything else — no pointer, a
    // malformed one, one that cannot be read yet — is `pending/`, the one directory this process
    // creates. nil only when the App-Group container itself cannot be resolved: nothing is written.
    public static func tunnelAnalyticsDirectory(container: URL? = nil) -> TunnelAnalyticsDirectory? {
        guard let appGroup = container ?? defaultContainer() else { return nil }
        if case .current(let name) = AnalyticsLedger.readPointer(in: appGroup) {
            return TunnelAnalyticsDirectory(url: AnalyticsLedger.containerDirectory(named: name, in: appGroup), isPending: false)
        }
        let pending = AnalyticsLedger.containerDirectory(named: AnalyticsLedger.pendingName, in: appGroup)
        do {
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        } catch {
            // Not a verdict on anything: the write that follows fails and keeps its delta for the next.
        }
        return TunnelAnalyticsDirectory(url: pending, isPending: true)
    }

    // MARK: The tunnel's write (P9g)

    // What one write of the tunnel's document came to. The caller holds what accrued since its last
    // successful write — a DELTA, never a copy of the document — and acts on the answer.
    public enum TunnelAnalyticsFold: Equatable, Sendable {
        // Written; the caller starts a new delta.
        case written(AnalyticsDocument)
        // Nothing written: the file cannot be read yet, a newer build wrote it, its unreadable bytes
        // have nowhere to go, or the write failed — the container's directory missing included. The
        // caller KEEPS its delta and offers it again at the next write.
        case deferred
        // The document this session already wrote is gone — the reset deleted it, between two writes
        // or during this one (or, in `pending/`, adoption moved it away). Nothing written; in an
        // account's container the caller DROPS its delta: it accrued at least in part before the reset,
        // and writing it would carry cleared history into the new one.
        case resetDetected
    }

    // THE EXTENSION'S WRITE, and the only one: read the document in `directory` (the session's, from
    // tunnelAnalyticsDirectory), add `delta`, write it back. `documentExpected` is "this session has
    // already written the document" — the caller's memory of its own last `.written`, which is what
    // makes an absent file mean a reset rather than a first run. Never throws and never waits on
    // anything but the file system: stopTunnel runs on a deadline.
    public static func foldTunnelAnalytics(
        _ delta: AnalyticsDocument,
        documentExpected: Bool,
        in directory: URL,
        now: Date,
        calendar: Calendar
    ) -> TunnelAnalyticsFold {
        let name = AnalyticsLedger.tunnelDocumentName
        switch AnalyticsLedger.read(named: name, in: directory) {
        case .unavailable:
            return .deferred
        case .document(let onDisk):
            // A newer build's document is read by the app and never written from here.
            guard onDisk.isWritable else { return .deferred }
            return outcome(replaceTunnelDocument(onDisk.merging(delta), existing: true, in: directory, now: now, calendar: calendar))
        case .unreadable:
            // The ledger's rule: moved aside, never written over; with the slot taken, nothing is written.
            guard AnalyticsLedger.moveAside(named: name, in: directory) else { return .deferred }
            return createTunnelDocument(delta, in: directory, now: now, calendar: calendar)
        case .absent:
            if documentExpected { return .resetDetected }
            return createTunnelDocument(delta, in: directory, now: now, calendar: calendar)
        }
    }

    // No document: a new one. The v1 totals this used to carry in (P9g) are at the App-Group root, which
    // this process no longer reads — the app adopts them (P9h) — so a new document is the delta alone.
    private static func createTunnelDocument(
        _ delta: AnalyticsDocument, in directory: URL, now: Date, calendar: Calendar
    ) -> TunnelAnalyticsFold {
        outcome(replaceTunnelDocument(
            AnalyticsDocument(since: delta.since).merging(delta), existing: false, in: directory, now: now, calendar: calendar
        ))
    }

    private static func outcome(_ replacement: TunnelDocumentReplacement) -> TunnelAnalyticsFold {
        switch replacement {
        case .written(let written): return .written(written)
        case .vanished: return .resetDetected
        case .failed: return .deferred
        }
    }

    enum TunnelDocumentReplacement: Equatable {
        case written(AnalyticsDocument)
        // `existing` was true and the document was no longer there to replace.
        case vanished
        case failed
    }

    // AnalyticsLedger.write's sequence — the schema guard, revision + 1, the day ring pruned, sorted
    // keys, protected until first unlock — with ONE difference, which is why this exists: the final
    // rename is CONDITIONAL. Replacing swaps the staged bytes in with RENAME_SWAP, which fails ENOENT
    // when the document is no longer there; creating uses RENAME_EXCL, which fails when one has
    // appeared. A plain atomic write cannot tell: it would recreate a document the reset deleted
    // between this read and this write — the Reset row can be pressed while this process is mid-write —
    // and put the cleared numbers back; in `pending/` it would write over a document adoption had just
    // moved away. Internal for the suites only.
    static func replaceTunnelDocument(
        _ document: AnalyticsDocument, existing: Bool, in container: URL, now: Date, calendar: Calendar
    ) -> TunnelDocumentReplacement {
        guard document.isWritable else { return .failed }
        var written = document
        written.revision = AnalyticsDocument.saturatingSum(written.revision, 1)
        written.pruneDays(now: now, calendar: calendar)
        let target = AnalyticsLedger.url(named: AnalyticsLedger.tunnelDocumentName, in: container)
        // Beside the document, so the rename never crosses a volume. After a swap it holds the
        // REPLACED bytes and is removed at once; one left by a process killed mid-write is removed by
        // the next write before it stages.
        let staging = AnalyticsLedger.url(named: AnalyticsLedger.tunnelStagingName, in: container)
        try? FileManager.default.removeItem(at: staging)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(written).write(to: staging, options: AnalyticsLedger.writeOptions)
        } catch {
            return .failed
        }
        let flags = UInt32(existing ? RENAME_SWAP : RENAME_EXCL)
        let failure: Int32 = staging.withUnsafeFileSystemRepresentation { from in
            target.withUnsafeFileSystemRepresentation { to in renamex_np(from, to, flags) == 0 ? 0 : errno }
        }
        try? FileManager.default.removeItem(at: staging)
        guard failure == 0 else { return existing && failure == ENOENT ? .vanished : .failed }
        return .written(written)
    }

    #if os(macOS)
    // MARK: - The Mac's cache name, and a revoke the app still owes (T-MAC-26, T-MAC-26h)

    // The extension's cache, at the root of the container the EXTENSION resolves — root's, since it runs
    // as root (T-MAC-14) — and outside removeEngineWorkspace's list. TunnelConfigCache owns its format.
    public static let tunnelConfigCacheName = "tunnel-config-cache"

    // T-MAC-26h: A REVOKE THAT DID NOT LAND IS OWED. Sign-out, Reset, account deletion and a lapse ask the
    // extension over XPC to discard this macOS user's record (TunnelControl's `revoke`). When that fails — no
    // listener, no reply, a removal that failed — the record may still be there for any start to run, so the app
    // records the debt here, in its OWN container (the console user's), and the next launch's reconciliation sends
    // the revoke again (VPNCore.disarmOnDemand). A confirmed revoke clears it, and so does a confirmed put: the put
    // replaced the record, so nothing of the one to revoke is left. Presence of the file is the value; not a
    // secret, it names nothing. Retired here with it (T-MAC-26h): T-MAC-26b's record of the handed-over
    // generation (`tunnel-config-generation`) and T-MAC-26f's account generation (`tunnel-account-generation`),
    // with the profile binding they served; the app reads neither file again.
    private static let revokeOwedName = "tunnel-config-revoke-owed"

    // False when the record could not be written or removed (no container, a failed write), so the caller can
    // log it.
    @discardableResult
    public static func setMacOSRevokeOwed(_ owed: Bool, container: URL? = nil) -> Bool {
        guard let container = container ?? defaultContainer() else { return !owed }
        let url = container.appendingPathComponent(revokeOwedName)
        do {
            if owed {
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
                try Data().write(to: url, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch CocoaError.fileNoSuchFile where !owed {
            return true
        } catch {
            return false
        }
    }

    public static func isMacOSRevokeOwed(container: URL? = nil) -> Bool {
        guard let container = container ?? defaultContainer() else { return false }
        return FileManager.default.fileExists(atPath: container.appendingPathComponent(revokeOwedName).path)
    }
    #endif

    #if os(iOS)
    // MARK: - iOS sing-box config location (T-CFG-41)
    //
    // On iOS the config bytes live in the SHARED KEYCHAIN (SharedKeychain.loadTunnelConfig), not in
    // providerConfiguration — they carry a live proxy credential (the per-account VLESS UUID) plus the
    // REALITY parameters, and NE preferences are unencrypted for as long as the profile is installed.
    // What stays in providerConfiguration is this NON-SECRET marker: it says a config is expected, and
    // nothing about which one. macOS keeps the bytes in neither place: its root-run sysext can read
    // neither the user keychain nor the app's App-Group container (T-MAC-14), so they travel over the
    // extension's XPC service into a root-only cache of the extension's own (T-MAC-26h, TunnelControl).
    //
    // WHY A MARKER AT ALL, when the extension could simply read the Keychain and refuse on nil. It
    // separates two failures that otherwise look identical at the gate and need different responses:
    // a profile this build never saved (an install upgraded from a build that stored the bytes in
    // providerConfiguration — see below) versus a stored config that is missing or unreadable. Both
    // refuse the start; only the first is expected, and one log line apart they are indistinguishable.
    //
    // UPGRADE PATH — RE-FETCH, NOT MIGRATE (decision). An install upgraded across this change has bytes
    // in providerConfiguration and nothing in the Keychain; the iOS read path ignores those bytes
    // entirely, so an on-demand raise refuses until the user connects once from the app. That connect
    // re-fetches (or reuses the cached config), stores it here, and REPLACES providerConfiguration with
    // this marker alone — which is also what finally drops the stale credential out of NE preferences.
    // Migrating instead would save one round trip and cost a launch-time NE preferences read+write plus
    // a code path that is dead the moment every install has connected once. Re-fetch is the same path
    // that must already heal a missing or stale store after the go-live REALITY rotation (Q34 /
    // B-SAFE-3, no grace window), so it is the one path worth having and worth exercising.
    public static let iOSConfigInKeychainKey = "configInKeychain"

    // The extension's marker predicate, in one place so the app's write and the appex's read cannot
    // drift. FAIL-CLOSED by construction: a nil dictionary, an absent key, `false`, and any non-Bool
    // value all read as "no config expected". Pure and nonisolated so the off-device suite can assert
    // the whole table (same seam as VPNCore.deauthorizedProviderConfiguration — every NE call around it
    // needs a provisioned device).
    public static func expectsKeychainConfig(_ providerConfiguration: [String: Any]?) -> Bool {
        providerConfiguration?[iOSConfigInKeychainKey] as? Bool == true
    }

    // MARK: - iOS activation-key fingerprint (T-CFG-45)
    //
    // Binds the iOS start-time gate to the CONFIG IT IS ABOUT TO RUN. The appex used to run two guards
    // that never talked to each other: it read the activation key from the shared Keychain, checked it
    // was non-empty and discarded it, then separately read providerConfiguration[singBoxConfigKey] — so
    // ANY non-empty key unlocked WHATEVER config happened to be sitting in the profile. Reachable
    // because sign-out's removeProfile() is best-effort (a throw leaves the profile + on-demand rules
    // armed) and, more importantly, because T-AUTH-19 deliberately RETAINS the key and the profile on an
    // involuntary session expiry: paste a DIFFERENT account's key on the Welcome screen and the Keychain
    // holds account B's key while providerConfiguration still holds account A's VLESS config — an
    // on-demand trigger then raises the tunnel on A's credentials.
    //
    // WHY A FINGERPRINT AND NOT A PRESENCE MARKER. A presence marker is the obvious symmetric fix and it
    // is INSUFFICIENT: one written on connect and cleared on sign-out is still PRESENT in the expiry
    // path above, because no sign-out ever ran. The gate must compare IDENTITY, not existence — so this
    // file carries the digest of the key that was live when the config was saved, and startTunnel
    // re-hashes the key it just read and requires equality.
    //
    // WHY AN UNSALTED DIGEST IS ACCEPTABLE. The activation key is 16 Crockford base32 characters = 80
    // bits of uniform random entropy, so the digest is neither brute-forceable nor a dictionary target;
    // a salt would add a second stored value with no threat it defends against (and would fail the
    // smallest-change test). ONLY the digest is written — the key itself never leaves the Keychain
    // (CLAUDE.md). File protection is the iOS default (complete-until-first-user-authentication), which
    // matches the key item's kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: pre-first-unlock the
    // Keychain read already fails, so the two gates become unavailable together, never apart.
    //
    // Second, independent property: TunnelWorkspace.wipe() clears this file on sign-out INDEPENDENTLY of
    // removeProfile(), so a thrown profile removal still fails the gate closed.

    // Fingerprint file name inside the App-Group container.
    private static let iOSKeyFingerprintName = "ios-key-fingerprint"

    // SHA-256 over the key's UTF-8 bytes. The ONLY derivation — write and compare must never diverge.
    private static func fingerprint(of activationKey: String) -> Data {
        Data(SHA256.hash(data: Data(activationKey.utf8)))
    }

    // Writes the digest of the key that authorises the config being saved. Best-effort (try?): a write
    // failure leaves the PREVIOUS digest in place, which is the fail-closed outcome — it still matches
    // for the same account and still refuses for a different one. Called right after the tunnel config is
    // stored: from VPNCore.connect after saveToPreferences and before startVPNTunnel (T-CFG-59), and from
    // VPNCore.storeConfig while the tunnel is down, with no profile save (T-CFG-70), so it is present for
    // the start-time guard. TunnelWorkspace.rebindKeyFingerprint also writes it: it re-points the digest
    // to a rotated key, with no config store (T-AUTH-29).
    public static func writeIOSKeyFingerprint(for activationKey: String, container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        try? fingerprint(of: activationKey).write(to: container.appendingPathComponent(iOSKeyFingerprintName))
    }

    // True iff the stored digest exists AND equals the digest of `activationKey`. An unresolvable
    // container, an unreadable/absent file, and a truncated or otherwise non-matching digest ALL read
    // false — FAIL-CLOSED. Called from the iOS startTunnel guard.
    public static func iOSKeyFingerprintMatches(_ activationKey: String, container: URL? = nil) -> Bool {
        guard let container = container ?? defaultContainer() else { return false }
        guard let stored = try? Data(contentsOf: container.appendingPathComponent(iOSKeyFingerprintName)) else {
            return false
        }
        return stored == fingerprint(of: activationKey)
    }

    // Removes the fingerprint. Best-effort (try?): a missing file is a no-op, so sign-out stays
    // BEST-EFFORT and this never throws or blocks the wipe path. Called from TunnelWorkspace.wipe(),
    // which sign-out runs unconditionally AFTER the best-effort removeProfile() — so the gate is cleared
    // regardless of removeProfile()'s outcome.
    public static func clearIOSKeyFingerprint(container: URL? = nil) {
        guard let container = container ?? defaultContainer() else { return }
        try? FileManager.default.removeItem(at: container.appendingPathComponent(iOSKeyFingerprintName))
    }

    // MARK: - A rule-set the engine refused (T-ROUTE-8)
    //
    // WHAT IT RECORDS: the SHA-256 of each local rule-set file a start was refused with, when the SAME
    // config without the Smart merge then came up in the extension's one retry (PacketTunnelProvider).
    // The app consumes it (RuleSetStore.verifiedLists) and marks the list unusable when a digest is the
    // one it recorded for the file now in place; any other digest is dropped.
    //
    // WHY IT EXISTS. Only the extension sees the engine's start error, and it sees it on every start
    // path: an on-demand raise, the widget, Control Center and Siri run no app code that could watch the
    // start (T-ROUTE-6's supervisor watches an in-app Connect only). The extension cannot remove the cause
    // itself — the app owns the stored config (T-CFG-41 / T-CFG-70) and the list (RuleSetStore) — so it
    // runs the full tunnel and tells the app which bytes were refused.
    //
    // WHY A DIGEST, NOT A FLAG OR A PATH. The path stays the same when the list is replaced, so a flag or
    // a path would blame whatever list sits there by the time the app looks. The digest is of the bytes
    // read right after the refusal, before the retry, so a later replacement is never blamed.
    //
    // Consumed rather than read, and best-effort both ways (`try?`, like the re-arm intent above): a
    // lost write or a marker lost to a race with the app costs one more refused start and its retry,
    // never a list blamed in error. Not a secret — a published list's digest, no account, no path — so
    // TunnelWorkspace.wipe() leaves it. Protection is the iOS default (until first user authentication),
    // the class the list file and the stored config's Keychain item already have.

    private static let refusedRuleSetsName = "ruleset-refused.json"

    // The extension's half, step 1: the SHA-256 of each file, read NOW — right after the refusal, before
    // the retry. An unreadable file names nothing. Mapped when the system allows it, not copied: this runs
    // inside the Packet-Tunnel memory budget.
    public static func ruleSetDigests(atPaths paths: [String]) -> [String] {
        paths.compactMap { path in
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
                return nil
            }
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    // Step 2, once the retry came up. Replaces a marker the app has not consumed yet: the newest refusal
    // names the list in place now. False when nothing was written — no digest, no container, or the write
    // failed.
    @discardableResult
    public static func setRefusedRuleSets(_ digests: [String], container: URL? = nil) -> Bool {
        guard !digests.isEmpty, let container = container ?? defaultContainer() else { return false }
        do {
            try JSONEncoder().encode(digests)
                .write(to: container.appendingPathComponent(refusedRuleSetsName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // The app's half: the digests, and the marker removed — whether or not one of them is the list in
    // place. nil: no marker. A marker that cannot be decoded is removed all the same and names nothing.
    public static func takeRefusedRuleSets(container: URL? = nil) -> [String]? {
        guard let container = container ?? defaultContainer() else { return nil }
        let url = container.appendingPathComponent(refusedRuleSetsName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    #endif
}
