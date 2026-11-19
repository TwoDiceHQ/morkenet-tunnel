// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Two Dice Ltd
//
// This file is part of the Morke VPN Network Extension, which statically links
// sing-box (https://github.com/SagerNet/sing-box), licensed GPL-3.0-or-later.
// GPLv3 § 5(c) requires the entire work, as a whole, to be licensed under the same
// terms to anyone who comes into possession of a copy — so this file is GNU General
// Public License v3 or later.
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

import NetworkExtension
import OSLog
import WidgetKit
import MorkeShared

// os_log destination for all Network Extension lifecycle events.
// Console.app filter: Subsystem = "tech.twodice.morke", Category = "tunnel"
private let log = Logger(subsystem: MorkeLog.subsystem, category: "tunnel")

// @objc name is pinned so NSExtensionPrincipalClass = "PacketTunnelProvider" in Info.plist
// resolves correctly regardless of Swift module name changes (T-RENAME-1).
@objc(PacketTunnelProvider)
final class PacketTunnelProvider: NEPacketTunnelProvider {

    // SingBoxTunnel is created lazily inside startTunnel, never at init: keep the Go runtime out of
    // class initialisation. (Eager libbox was NOT the iOS 26.5 launch crash; see
    // Docs/reference/singbox-integration.md § "No libbox in principal init".)
    private var singBox: SingBoxTunnel?

    // T-INFRA-27: when this process accepted a start, so the app can report an uptime. Written and
    // read on the provider queue only.
    private var startedAt: Date?
    // T-INFRA-27: size of the config this start ran, in BYTES. Never the config.
    private var configBytes: Int?
    #if os(iOS)
    // P9g: this start's analytics — created with it, stopped with it (TunnelAnalytics.swift). Written
    // and read on the provider queue only, like the two above. iOS ONLY, and its file is a member of the
    // iOS target alone: the macOS system extension runs as root, so the App-Group container it reaches
    // is root's, which the app can neither read nor reset (T-MAC-14 / T-MAC-15) — a document written
    // there would be residue nobody can clear.
    private var analytics: TunnelAnalyticsRecorder?
    #endif

    override init() {
        log.notice("PacketTunnelProvider: init")
        #if os(macOS)
        // T-MAC-26hb: a provider is created for a start, before its startTunnel runs, so the start is noted here
        // first: the exit a stop scheduled in this process (stopTunnel) then leaves it running. P78j's server
        // switch had this provider's init in the same millisecond as that exit (TunnelControl's WHAT COUNTS AS A
        // START).
        TunnelControl.providerStarts.noteStart()
        #endif
        super.init()
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.notice("startTunnel: requested")
        #if os(macOS)
        // T-MAC-26h: a start in this process, so the exit a stop scheduled (stopTunnel) leaves it running (noted at
        // init too, T-MAC-26hb; a second note changes nothing).
        TunnelControl.providerStarts.noteStart()
        #endif
        // T-INFRA-27: our own lifecycle events into the bounded App-Group ring, so an extension
        // that dies before the app can ask it anything still leaves a trace. Closed event set + an
        // optional Int by construction — nothing about traffic can pass through it.
        TunnelDiagnostics.record(.startRequested)

        // Authorization guard.
        #if os(macOS)
        // macOS: this system extension is SANDBOXED and runs AS ROOT in the system context, not the user
        // session — so it shares NEITHER of the two stores the iOS appex reads. It makes no SecItem call
        // (a process outside a user context sees only the System keychain, TN3137), and
        // containerURL(forSecurityApplicationGroupIdentifier:) resolves PER USER, so the App-Group
        // container reached from here is root's (/var/root/Library/Group Containers/…) and never the one
        // the app writes as the console user. Do not add an App-Group signal from the app: it can never be
        // found from here (T-MAC-10 required one, and no Mac start succeeded until T-MAC-14 removed it).
        //
        // THE GATE IS THE CACHE (T-MAC-26h, P84 point 4): there is no separate authorisation here. The app puts
        // the config over this extension's XPC service (TunnelControl, which accepts only our signed app) and
        // takes it away with a revoke at sign-out, Reset, deletion and a lapse; a start runs the record when it
        // holds one and refuses otherwise, whatever start it is. This provider's view of the profile decides
        // nothing: on this macOS it can lag the app's save (P78e/f/g), which is what T-MAC-26b to 26f's
        // auth flag, generation, start token and `viewAgrees` fought. The config guard below is the whole
        // decision.
        #else
        // Authorization guard: require a non-empty activation key in Keychain that MATCHES the config
        // this start is about to run (T-CFG-45, second guard below).
        // On on-demand reconnect (no app running) the OS re-delivers the stored
        // providerConfiguration, so the key is read directly — no app wake needed.
        //
        // do/catch (not try?) so a transient keychain failure — e.g. errSecInteractionNotAllowed on
        // a pre-first-unlock on-demand start — surfaces its distinct OSStatus instead of collapsing
        // into the same "key absent" line as a genuinely-missing key (L5). Log only the numeric
        // status + a generic message: never the key, its presence, or its value.
        do {
            guard
                let key = try SharedKeychain.loadActivationKey(),
                !key.isEmpty
            else {
                log.error("startTunnel: failed — activation key absent from Keychain")
                refuseStart(.notAuthorized, completionHandler)
                return
            }
            // T-CFG-45: presence is not enough — require the key to be THE key this config was saved
            // for. The app writes SHA-256(activation key) into the App-Group container right AFTER it
            // stores the config read below in the shared Keychain: in VPNCore.connect after the profile
            // save and before startVPNTunnel (T-CFG-59), and in VPNCore.storeConfig while the tunnel is
            // down, with no profile save (T-CFG-70). The one write with no store is a key change on the
            // same account (T-AUTH-29): TunnelWorkspace.rebindKeyFingerprint re-points the digest to the
            // new key, and only when it held the replaced key's. So a mismatch means the installed
            // config belongs to a different account than the one now in the Keychain — exactly what an
            // involuntary session expiry followed by a login with another key produces (T-AUTH-19
            // retains both the key and the profile), and what a presence-only marker would wave
            // through. Absent / unreadable digest ⇒ no match ⇒ refuse.
            // Generic log line only: never the key, the digest, the account, or the config.
            guard AppGroup.iOSKeyFingerprintMatches(key) else {
                log.error("startTunnel: failed — activation key does not match the installed configuration")
                refuseStart(.notAuthorized, completionHandler)
                return
            }
        } catch SharedKeychainError.unexpectedStatus(let status) {
            log.error("startTunnel: failed — keychain read error (OSStatus \(status, privacy: .public))")
            refuseStart(.notAuthorized, completionHandler)
            return
        } catch {
            log.error("startTunnel: failed — keychain read error")
            refuseStart(.notAuthorized, completionHandler)
            return
        }
        #endif

        // Config guard. The app stores the config before every connect (see VPNManagerClient.connect);
        // on an on-demand reconnect there is no app process, so whatever it stored last is what runs.
        // WHERE it is stored is per-platform and NOT a preference — see below.
        #if os(iOS)
        // T-CFG-41: the bytes live in the SHARED KEYCHAIN and providerConfiguration carries only a
        // non-secret marker, because the config is a live proxy credential (per-account VLESS UUID +
        // REALITY params) and NE preferences are unencrypted for as long as the profile is installed.
        //
        // Marker first: absent means this profile was not saved by a build that stores the config here —
        // an install upgraded across T-CFG-41, whose stale providerConfiguration bytes are deliberately
        // NOT read. It refuses the start; the next in-app connect re-fetches, stores, and replaces
        // providerConfiguration with the marker alone. Distinct log line from a missing store, which is
        // the whole reason the marker exists.
        guard AppGroup.expectsKeychainConfig(
            (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        ) else {
            log.error("startTunnel: failed — profile does not expect a stored config (connect from the app once)")
            refuseStart(.missingConfig, completionHandler)
            return
        }
        // The store is a CACHE, never the only copy (Q34): a missing or unreadable item FAILS THE START
        // CLOSED here and is repaired by an ordinary foreground connect — which is also what has to heal
        // the go-live REALITY rotation (B-SAFE-3, one announced rotation with no grace window). No
        // re-fetch is attempted from here, deliberately: an on-demand raise has no app process and
        // possibly an expired JWT, so a fetch would fail exactly when the tunnel matters most.
        //
        // do/catch (not try?) so a transient keychain failure — e.g. errSecInteractionNotAllowed on a
        // pre-first-unlock on-demand start — surfaces its OSStatus instead of collapsing into the same
        // line as a genuinely-absent config, mirroring the activation-key read above. That pre-first-
        // unlock case is NOT new: the key read above already fails there, and both items share
        // SharedKeychain.accessibility, so the two become unavailable together, never apart.
        let configData: Data
        do {
            guard let stored = try SharedKeychain.loadTunnelConfig() else {
                log.error("startTunnel: failed — no stored sing-box config (connect from the app to restore it)")
                refuseStart(.missingConfig, completionHandler)
                return
            }
            configData = stored
        } catch SharedKeychainError.unexpectedStatus(let status) {
            log.error("startTunnel: failed — sing-box config keychain read error (OSStatus \(status, privacy: .public))")
            refuseStart(.missingConfig, completionHandler)
            return
        } catch {
            log.error("startTunnel: failed — sing-box config keychain read error")
            refuseStart(.missingConfig, completionHandler)
            return
        }
        guard
            let configJSON = String(data: configData, encoding: .utf8),
            !configJSON.isEmpty
        else {
            log.error("startTunnel: failed — stored sing-box config is empty or not UTF-8")
            refuseStart(.missingConfig, completionHandler)
            return
        }
        #else
        // macOS (T-MAC-26, rebuilt by T-MAC-26h): the bytes are NOT in providerConfiguration. Its store,
        // /Library/Preferences/com.apple.networkextension.plist, is root:wheel 0644, readable by every local
        // account (T-MAC-20). The app puts the config over this extension's XPC service before it starts the
        // tunnel (TunnelControl, MorkeTunnelMac/main.swift), and this process keeps it in a 0600 cache in ITS
        // App-Group container — root's, unreadable to every other account (TunnelConfigCache). EVERY start runs
        // that cache: an in-app Connect, on-demand, the Kill Switch's always-on rule, System Settings, the
        // menu-bar VPN item, a reboot.
        //
        // NO CONFIG FROM START OPTIONS. Any process may request a start with options of its own
        // (SCNetworkConnectionStart's userOptions), so nothing in them is read; a constant line says they came.
        //
        // WHAT A START RUNS (TunnelConfigCache's header): the record, when it is intact — version, length,
        // SHA-256. Anything else is refused with .missingConfig (the T-CFG-41 rule: the next in-app Connect
        // repairs it), one public line naming the reason and never a value; only a record no start can ever run
        // is deleted. Read on TunnelControl.queue, so it never interleaves with a put or a revoke on the file.
        //
        // T-CFG-17 on the Mac: THE STACK FOLLOWS THE KILL SWITCH THE APP TOLD THIS EXTENSION (the maintainer,
        // 2026-11-17, «Как на iOS, с XPC»): gVisor with it on, the server's `system` stack with it off, as on iOS.
        // The Kill Switch is the record's flag, which the app sets over XPC with every put and on every Kill
        // Switch change, ON before it saves includeAllNetworks and OFF after (TunnelConfigCache's header), never
        // this provider's view of includeAllNetworks: that view can lag the app's save (P78e/f/g), and T-MAC-26h's
        // independent review found a Kill Switch switched on in Settings, with on-demand armed, whose first start
        // saw neither. startConfig returns the config already on that stack; a start reads nothing from its view
        // of the profile at all.
        let decision = TunnelControl.queue.sync { TunnelConfigCache.startConfig(options: options) }
        if decision.optionsIgnored {
            log.notice("startTunnel: start options ignored, the config comes only from the cache (T-MAC-26h)")
        }
        let configData: Data
        switch decision.outcome {
        case .config(let runnable):
            log.notice("startTunnel: config read from the cache (T-MAC-26)")
            if decision.killSwitch {
                log.notice("startTunnel: the Kill Switch the app set is on, the gVisor stack is used (T-MAC-26h)")
            }
            configData = runnable
        case .refused(let reason, let discard):
            log.error("startTunnel: failed — \(reason.rawValue, privacy: .public) (connect from the app once)")
            logCacheDiscard(discard)
            refuseStart(.missingConfig, completionHandler)
            return
        }
        guard
            let configJSON = String(data: configData, encoding: .utf8),
            !configJSON.isEmpty
        else {
            log.error("startTunnel: failed — sing-box config is empty or not UTF-8")
            refuseStart(.missingConfig, completionHandler)
            return
        }
        #endif

        // Log config size (bytes) only — never log the config content, keys, or JWT.
        log.notice("startTunnel: config received (\(configData.count, privacy: .public) bytes)")

        // SingBoxTunnel is created on the NE provider queue so singBox is safely written
        // before the background work begins. box.start is moved off the provider queue:
        // openTun calls setTunnelNetworkSettings whose completion is delivered back to
        // this queue — running start() here would deadlock (queue blocked waiting on itself).
        let box = SingBoxTunnel()
        singBox = box
        // T-INFRA-27: both set on the provider queue, before the handoff below, so the background
        // closure never mutates provider state off-queue. The recorder likewise — it begins only once
        // the start comes up, from the closure, through its own queue.
        startedAt = Date()
        configBytes = configData.count
        #if os(iOS)
        let recorder = TunnelAnalyticsRecorder()
        analytics = recorder
        #endif
        // `self` (the NE provider) and `completionHandler` are non-Sendable, but this is a single,
        // one-shot handoff onto the background queue: start() runs once (twice on iOS when T-ROUTE-8's
        // retry runs, in sequence, from this one closure), `self` is used only to bridge packet I/O
        // through ExtensionPlatformInterface (NE-synchronised), and the handler is invoked exactly
        // once. There is no shared mutable state to race, so the narrow nonisolated(unsafe) is
        // warranted. The off-queue dispatch itself is mandatory (the deadlock above).
        nonisolated(unsafe) let provider = self
        nonisolated(unsafe) let completion = completionHandler
        DispatchQueue.global(qos: .userInitiated).async {
            // The start came up — the first one, or on iOS the one retry below (`startedBytes` is the
            // size of the config that came up).
            func cameUp(startedBytes: Int) {
                log.notice("startTunnel: tunnel started successfully")
                TunnelDiagnostics.record(.startSucceeded, detail: startedBytes)
                #if os(iOS)
                // P9g: the start came up — `tunnelStarts` +1 and the session's clock starts. Never on a
                // refusal (those return above without reaching here) nor on a throw (below).
                recorder.begin()
                #endif
                completion(nil)
            }
            do {
                try box.start(configJSON: configJSON, provider: provider)
                cameUp(startedBytes: configData.count)
            } catch {
                log.error("startTunnel: libbox start failed — \(error.localizedDescription, privacy: .public)")
                TunnelDiagnostics.record(.startFailed)
                #if os(iOS)
                // T-ROUTE-8 (decided by the maintainer, 2026-10-26: when the engine refuses, the
                // extension retries the start once without the list's merge): a config that names a
                // local rule-set gets ONE more start without the Smart merge — the full tunnel,
                // `route.final` untouched — because a list the engine cannot load (an SRS version above
                // its own, a rule type it refuses) fails the start at the engine, on every start path,
                // and only this process sees that. An armed on-demand would otherwise restart the
                // refused config in a loop, offline under the Kill Switch, until an in-app Connect
                // (T-CFG-52's shape). The stored config is not rewritten here — the app owns it
                // (T-CFG-41 / T-CFG-70) — so each start that still names the list pays one failed start
                // and this retry until the app takes the marker. The teardown runs first
                // (discardFailedStart), and the retry is the last attempt: its own failure tears down and
                // reports as below.
                if let retry = Self.fullTunnelRetry(for: configData), box.discardFailedStart() {
                    log.notice("startTunnel: libbox refused the start with a local rule-set — retrying once without it (T-ROUTE-8)")
                    let started: Bool
                    do {
                        started = try box.start(configJSON: retry.configJSON, provider: provider)
                    } catch {
                        log.error("startTunnel: libbox start failed — \(error.localizedDescription, privacy: .public)")
                        TunnelDiagnostics.record(.startFailed)
                        box.stop()
                        completion(error)
                        return
                    }
                    // Only a retry that came up shows the list at fault — the same config without the
                    // merge started — so only then is the app told. One a stop overtook proves nothing.
                    if started {
                        if AppGroup.setRefusedRuleSets(retry.refusedDigests) {
                            log.notice("startTunnel: the refused rule-set is recorded for the app (T-ROUTE-8)")
                        } else {
                            log.error("startTunnel: the refused rule-set could not be recorded — the next start retries again (T-ROUTE-8)")
                        }
                    }
                    cameUp(startedBytes: retry.configBytes)
                    return
                }
                #endif
                // A thrown start can leave the engine half-up (command server, published
                // platformInterface, possibly applied TUN settings): the OS does NOT deliver
                // stopTunnel for a failed start, so run the deliberate closeService → reset → close
                // teardown here before reporting. box.stop() is idempotent / race-latched (M8).
                box.stop()
                completion(error)
            }
        }
    }

    #if os(macOS)
    // T-MAC-26: what became of a cache a refusal discarded. A constant and an errno, never a path.
    private func logCacheDiscard(_ discard: TunnelConfigCache.Discard) {
        switch discard {
        case .notNeeded:
            break
        case .removed:
            log.notice("startTunnel: config cache discarded (T-MAC-26)")
        case .failed(let code?):
            log.error("startTunnel: config cache discard failed, errno=\(code, privacy: .public) (T-MAC-26)")
        case .failed(nil):
            log.error("startTunnel: config cache discard failed, errno unavailable (T-MAC-26)")
        }
    }
    #endif

    #if os(iOS)
    // T-ROUTE-8: what the one retry runs, and what it tells the app. The config the failed start ran
    // with the Smart merge stripped (SingBoxConfigStrip, the same inverse the app's revert uses), and
    // the SHA-256 of each list it named, read NOW — right after the refusal, so the digest is of the
    // bytes the engine refused. nil — no retry, the start fails exactly as before T-ROUTE-8 — when the
    // config names no local rule-set. Coarse lines only: never the config, a list, a path or a digest.
    private static func fullTunnelRetry(
        for configData: Data
    ) -> (configJSON: String, configBytes: Int, refusedDigests: [String])? {
        let stripped: SingBoxConfigStrip.Stripped?
        do {
            stripped = try SingBoxConfigStrip.strip(SingBoxConfig(raw: configData))
        } catch {
            log.error("startTunnel: the refused config could not be stripped — no retry (T-ROUTE-8)")
            return nil
        }
        guard let stripped, !stripped.ruleSetPaths.isEmpty,
              let configJSON = String(data: stripped.config.raw, encoding: .utf8)
        else { return nil }
        return (configJSON, stripped.config.raw.count, AppGroup.ruleSetDigests(atPaths: stripped.ruleSetPaths))
    }
    #endif

    // MARK: - Refusal delivery (T-CFG-52 measurement 2)
    //
    // Every guard above refuses through this ONE seam so the delivery STYLE can be varied without
    // touching a single gate. Shipping builds compile only `completionHandler(error)`; the two
    // variants, selected by -D flags that no scheme and no xcconfig sets, answer one question: does
    // the style change iOS's retry cadence? Neither is a candidate fix — `cancelTunnelWithError(nil)`
    // never calls the completion handler, and complete-then-stop lies to the OS that a tunnel came up.
    //
    // KEPT after T-CFG-52 closed (maintainer, 2026-08-16). Measured answer, so nobody re-runs it: all
    // three styles produce the SAME ~20.3 s iOS cadence — the ceiling is Apple's, not the style's —
    // and complete-then-stop never reaches `.connected` at all, so it costs honesty and buys nothing.
    // Usage and build commands: Docs/reference/smoke-test.md § Device-verification harness; the
    // numbers: Docs/reference/closed-work-cfg.md § T-CFG-52. **Adding a guard above means calling THIS
    // seam**; a direct completionHandler call would be silently skipped by every future style
    // measurement.
    private func refuseStart(_ error: TunnelStartError, _ completionHandler: @escaping (Error?) -> Void) {
        // T-INFRA-27: every refusal is recorded here for the same reason every refusal is
        // DELIVERED here — one seam, so a future guard cannot forget either half.
        switch error {
        case .notAuthorized: TunnelDiagnostics.record(.startRefusedNotAuthorized)
        case .missingConfig: TunnelDiagnostics.record(.startRefusedMissingConfig)
        }
        #if MORKE_REFUSE_STYLE_CANCEL
        log.notice("refusal style: cancelTunnelWithError(nil), completion handler NEVER called (measurement 2)")
        cancelTunnelWithError(nil)
        #elseif MORKE_REFUSE_STYLE_COMPLETE_THEN_STOP
        log.notice("refusal style: completionHandler(nil) then cancelTunnelWithError(nil) — reports a tunnel that is NOT up (measurement 2)")
        completionHandler(nil)
        cancelTunnelWithError(nil)
        #else
        completionHandler(error)
        #endif
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.notice("stopTunnel: reason \(reason.rawValue, privacy: .public)")
        TunnelDiagnostics.record(.stopped, detail: reason.rawValue)
        #if os(iOS)
        // P9g: the session's last fold FIRST, while the engine is still up — its last traffic total is
        // the engine's, and the recorder closes its status client before the server goes (P9gb). One
        // read, one add, one write of a few KB; it never throws, and it waits at most for a checkpoint
        // already writing.
        analytics?.stop(reason: reason.rawValue, includeAllNetworks: protocolConfiguration.includeAllNetworks)
        analytics = nil
        #endif
        singBox?.stop()
        singBox = nil
        publishStoppedToSurfaces()
        #if os(macOS)
        // T-MAC-15: the engine is stopped, so its workspace goes now — root's container, which the app's
        // sign-out wipe cannot reach. After the surfaces, so the user-facing update never waits on it.
        SingBoxTunnel.scrubWorkspace(phase: "stopTunnel")
        #endif
        // T-INFRA-27: startedAt / configBytes are deliberately NOT cleared. `running` already says
        // the engine is gone (it reads `singBox != nil`), and what the report needs from a live but
        // idle extension is WHEN the last tunnel ran in it — clearing them made the report say "no
        // tunnel started in it" directly above an event ring showing a start and a stop seconds
        // earlier, which is the one thing a diagnostic must never do (maintainer, 2026-08-17).
        // (On macOS the process ends after the stop, below, so there it lives only until then.)
        completionHandler()
        #if os(macOS)
        // T-MAC-26h, P84 point 0 — THE PROCESS ENDS AFTER EVERY STOP, as Proton's system extension and
        // WireGuard's macOS provider do: "The system does not reliably reap provider processes, so exit once
        // the stop is acknowledged. Returning from this method is what sends the acknowledgment to the NE
        // framework, so the exit must come afterwards" (Proton, Provider.swift:105-121@d851e0f); WireGuard for
        // Apple bug 32073323, whose symptom is a start soon after a stop that the system kills (P84 § 01). This
        // process served every session of a run until now (P84 § 03 § 3.4, hypothesis H3). The record is a
        // file, so the next start, put or provider message finds it in a fresh process. The exit waits
        // TunnelControl.exitDelayAfterStop after the completion handler, runs on TunnelControl.queue so it
        // never cuts a put or a revoke in half, and is skipped when a start arrived meanwhile: a tunnel just
        // started in this process is never killed for the one that stopped. T-MAC-26hb: a start counts from the
        // put that precedes an in-app one, or from its provider's init, and the check and the exit are one step
        // (TunnelControl's WHAT COUNTS AS A START).
        let startsAtStop = TunnelControl.providerStarts.mark()
        TunnelControl.queue.asyncAfter(deadline: .now() + TunnelControl.exitDelayAfterStop) {
            let exited = TunnelControl.providerStarts.exitUnlessStarted(since: startsAtStop) {
                log.notice("stopTunnel: the provider process exits after the stop (T-MAC-26h, P84 point 0)")
                exit(EXIT_SUCCESS)
            }
            if !exited {
                log.notice("stopTunnel: a start arrived after the stop; the process stays for it (T-MAC-26h)")
            }
        }
        #endif
    }

    // MARK: - Telling the out-of-app surfaces the tunnel is down (T-EXT-1)
    //
    // ⚠️ THIS IS THE ONE PLACE THAT KNOWS. Device-found 2026-09-08: with the app swiped away, turning
    // the VPN off in Settings or Control Center left the widget counting a live timer — asserting
    // protection that did not exist — because a suspended app runs no NEVPNStatus observer, so the
    // App-Group document had no writer left. The log: `stopTunnel: reason 1` at 18:22:38 with not one
    // `Morke` line after it. Nothing on the widget's side can fix that; the document is the only
    // channel, and this process is the only witness left awake.
    //
    // WHY THIS CROSSES TWO RULES ON PURPOSE, both of them ours:
    //   • T-EXT-0 scoped extension-publishing OUT, and VPNSurfacePublisher's header still records the
    //     consequence it accepted. In the STOP direction it is worse than a surface lagging: a stale
    //     "connected" is a VPN telling someone they are protected when they are not.
    //   • The appex's link set is audited under a memory tier whose enforced metric is unresolved
    //     (T-CFG-16). The WRITE adds no link (`AppGroup` is in MorkeShared); `WidgetCenter` adds
    //     WidgetKit, a measured decision, not an assumption that a system framework is free
    //     (Docs/reference/smoke-test.md § Results — what the Home Screen widget costs). If the number
    //     moved, the reload goes and the widget polls for it instead.
    //
    // Deliberately narrow: status and connection start only. This process knows neither node nor
    // ping, and `updateVPNSurfaceState` merges, so the widget keeps showing the server it had.
    // Best-effort by construction — stopTunnel is on a deadline and nothing here may block it.
    private func publishStoppedToSurfaces() {
        AppGroup.updateVPNSurfaceState { state in
            state.status = .disconnected
            state.connectedSince = nil
            state.capturedAt = Date()
        }
        WidgetCenter.shared.reloadTimelines(ofKind: VPNSurfaceWidget.kind)
        // T-EXT-3: the Control Center control has no timeline at all, so this is the only thing that
        // can take its switch down when a VPN is stopped from outside the app. Same framework, no new
        // link, same best-effort caveat as the line above — and the same known residual, that this
        // XPC is sent from a process the system is tearing down and does not always land.
        //
        // ⚠️ `#if os(iOS)` AND NOT ONLY `#available`, because this file builds twice. `ControlCenter`
        // is iOS 18 / macOS 26, and the macOS system extension deploys to macOS 14 — an availability
        // check alone fails the Mac build outright, which is how this line was caught. There is
        // nothing to reload there in any case: the surfaces are iOS-only (VPNSurfacePublisher's
        // header), and the Mac app, active again since 2026-10-14, has none.
        #if os(iOS)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: VPNSurfaceWidget.controlKind)
        }
        #endif
        log.notice("stopTunnel: surfaces told — status=1 since=none (T-EXT-1)")
    }

    // MARK: - The protected-time total (T-UX-7 → P9g)
    //
    // ⚠️ THIS PROCESS IS THE ONLY WITNESS, for the same reason publishStoppedToSurfaces above it is: a
    // tunnel raised on demand and dropped hours later with the app suspended is invisible to the app,
    // and that is the ORDINARY case for a VPN nobody has to think about. The session is written as it
    // runs by TunnelAnalyticsRecorder (TunnelAnalytics.swift), whose header is the record of what it
    // writes, when, and why traffic is libbox's own totals rather than our utun's counters (P9gb).

    override func sleep(completionHandler: @escaping () -> Void) {
        log.notice("sleep: pausing tunnel")
        TunnelDiagnostics.record(.slept)
        #if os(iOS)
        // P9g: what accrued is written before the device sleeps.
        analytics?.checkpointBeforeSleep()
        #endif
        singBox?.pause()
        completionHandler()
    }

    override func wake() {
        log.notice("wake: resuming tunnel")
        TunnelDiagnostics.record(.woke)
        singBox?.wake()
        #if os(iOS)
        // libbox 1.14.4 keeps its device pause past `wake()` on iOS (only), so it is ended here; on
        // macOS `pause()` never sets it. T-ARCH-43b.
        singBox?.wakeNow()
        log.notice("wake: ended the engine's device pause")
        #endif
    }

    // MARK: - App → extension diagnostic message (T-INFRA-27)
    //
    // Deliberately trivial, and it must stay that way (the feature is permanent, T-INFRA-28): this
    // runs inside the Packet-Tunnel memory budget, and a growing message handler spends it. It
    // answers ONE request with THREE facts about this process — whether an engine object exists,
    // when the start was accepted, and the config's size in bytes. Any other payload gets a nil
    // reply, so this cannot grow into a command channel by accident. Nothing about traffic,
    // destinations or the config's content is readable through it.
    //
    // T-MAC-26h: on macOS too, this is the only request. T-MAC-26b's config handover and T-MAC-26f's revoke
    // moved off the provider-message channel onto the extension's XPC service (TunnelControl), which is how a
    // system extension talks to its app (Apple DTS) and keeps the provider message off the start path, the
    // one start shape that ever reset (P84 § 03). A handover or a revoke sent by an older app gets a nil reply,
    // like any other payload, and that app starts nothing.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard String(data: messageData, encoding: .utf8) == TunnelDiagnostics.stateRequest else {
            completionHandler?(nil)
            return
        }
        let state = TunnelDiagnostics.State(
            running: singBox != nil,
            startedAt: startedAt,
            configBytes: configBytes
        )
        completionHandler?(try? JSONEncoder().encode(state))
    }
}

// MARK: - TunnelStartError

private enum TunnelStartError: LocalizedError {
    case notAuthorized
    case missingConfig

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "No matching activation key in Keychain — connect from the app to authenticate first."
        case .missingConfig:
            // Deliberately does not name a store: it is the Keychain on iOS (T-CFG-41) and the extension's
            // root-only cache on macOS (T-MAC-26), and the user-facing remedy is the same either way.
            return "No sing-box config available — connect from the app to set it up first."
        }
    }
}
