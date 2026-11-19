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
import Libbox
import os
import MorkeShared

private let singBoxErrorDomain = "SingBoxTunnel"

// Same subsystem and category as PacketTunnelProvider, so a start reads as one timeline.
private let log = Logger(subsystem: MorkeLog.subsystem, category: "tunnel")

// Minimal sing-box engine wrapper for the Network Extension target.
// Vendored engine: sing-box v1.14.4, modified — see Docs/reference/singbox-integration.md and Frameworks/LIBBOX_VERSION.
// Owns the LibboxCommandServer lifecycle: setup → start → stop — and, on iOS, after a start that threw,
// discardFailedStart → start ONCE more (T-ROUTE-8).
//
// @unchecked Sendable: all mutable state (commandServer, platformInterface, stopped) is guarded
// by `lock` (see below), and the class is purpose-built for cross-thread use — start() runs on a
// background queue while stop/pause/wake run on the NE provider queue. The lock supplies the
// happens-before AND (via `stopped`) the start↔stop ordering, so the type is genuinely safe to
// share; this is a real conformance, not a checker silencer.
final class SingBoxTunnel: @unchecked Sendable {

    // The unfair lock gives the cross-thread pointer get/set (header above) a defined happens-before,
    // so ARC cannot over-release a field mid-teardown. It protects ONLY the pointers — every libbox
    // call is made on a local copy taken OUTSIDE the lock, preserving the deadlock-safe design where
    // box.start() (and openTun's semaphore wait) runs off the provider queue.
    private let lock = OSAllocatedUnfairLock()
    private var commandServer: LibboxCommandServer?
    private var platformInterface: ExtensionPlatformInterface?
    // One-way lifecycle latch (T-CFG-28, NE audit F-1/F-4): the lock gives memory safety but
    // not ordering — the OS can deliver stopTunnel while start() is still mid-flight (VPN
    // toggled off during a slow connect; NE start-timeout). stop() latches this under the lock
    // as it detaches the fields, so it wins the race deterministically; start() re-checks it
    // under the lock at every publication/use point and aborts instead of publishing onto (or
    // starting the engine of) a stopped tunnel. libbox guards only part of this itself: at the
    // pinned v1.14.1 a post-close startOrReloadService() returns os.ErrClosed, but start() listens
    // again, and nothing in libbox covers a stop() that ran before the server was published (v1.13.13
    // had no guard at all: a zombie engine, or a panic on the closed subscriber channels). The checks
    // shrink the race window to the few instructions between a check and the following libbox call —
    // it cannot be zero without holding the lock across libbox (forbidden: deadlock). start() runs at
    // most twice per object — the second time only after discardFailedStart (T-ROUTE-8) — and only
    // stop() sets the latch, so it never needs resetting.
    private var stopped = false

    // Initialises libbox, creates the command server, and starts the engine from a JSON config.
    // Must be called from startTunnel(_:completionHandler:). True: the engine started. False: a
    // stop() won the race and the engine was not started (the stop path owns the teardown).
    @discardableResult
    func start(configJSON: String, provider: NEPacketTunnelProvider) throws -> Bool {
        let iface = ExtensionPlatformInterface(provider: provider)
        // Lifecycle guard 1: stop() already won (e.g. stopTunnel landed before this block ran —
        // F-4). Nothing was published, so stop() saw nils and tore nothing down: reset the
        // local iface (never started, defensive no-op) and back out. Aborts return cleanly, not
        // throw: the provider's late completion(nil) on an already-stopping session is ignored
        // by the OS, and the stop path owns all teardown.
        lock.lock()
        if stopped {
            lock.unlock()
            iface.reset()
            return false
        }
        platformInterface = iface
        lock.unlock()

        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.appGroupID
        ) else {
            throw NSError(domain: singBoxErrorDomain, code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "App Group container not found — check entitlements"])
        }

        // T-CFG-67: delete the plaintext config copy an earlier engine left behind. Every libbox before
        // 1.14.1-morke.2 wrote the whole sing-box config (the per-account VLESS UUID and the REALITY
        // params) to <basePath>/configuration.json on each start, and nothing deleted it; morke.2 writes
        // nothing. It must run BEFORE LibboxSetup: Setup archives a pending crash log and copies this
        // file into the crash report beside it. Best-effort — the engine starts from configJSON in
        // memory, never from the file. TunnelWorkspace.wipe(container:) removes it on the app side too.
        removeStaleConfigSnapshot(in: container)
#if os(macOS)
        // T-MAC-15: and the rest of the engine's workspace, before LibboxSetup for the reason above —
        // Setup would archive a crashed session's log into Working/crash_reports. The previous stop
        // already removed it all; this covers a session that ended without one (a crash, a kill).
        Self.scrubWorkspace(in: container, phase: "start")
#endif

        let setupOpts = LibboxSetupOptions()
        setupOpts.basePath    = container.path
        setupOpts.workingPath = container.appendingPathComponent("Working").path
        setupOpts.tempPath    = container.appendingPathComponent("Library/Caches").path
        // Bounded in-memory log ring. Trim it in Release to claw back headroom under the
        // tight NE budget (it only feeds libbox's unused log-subscription feature); keep
        // deeper scrollback in Debug for on-device diagnosis. CONFIRM the resident delta
        // on device (NE memory gauge) — the NE does not run in the Simulator.
#if DEBUG
        setupOpts.logMaxLines = 3000
#else
        setupOpts.logMaxLines = 512
#endif
        // In-process memory hardening for the tight NE budget (Packet-Tunnel tier ~50 MiB on
        // iOS 15+; see roadmap T-CFG-16). Two knobs:
        //  (1) oomKillerEnabled: libbox's own OOM killer, so the engine self-limits rather than
        //      leaving the OS as the only backstop.
        //  (2) oomMemoryLimit: an explicit byte ceiling (T-CFG-30), because what 0 (unset) means — a
        //      sane NE default, or no effective ceiling and no Go GC soft-limit — cannot be told
        //      from the vendored binary. Derived AT RUNTIME (CLAUDE.md:
        //      never hardcode) from os_proc_available_memory() (os/proc.h, iOS 13+), the bytes this
        //      process can still allocate before jetsam: read here pre-engine it approximates the
        //      whole headroom. Give libbox 75% and keep 25% as the buffer that both absorbs the
        //      non-Go footprint (NE framework, ObjC/Swift) and makes libbox's GC/killer reclaim
        //      BEFORE jetsam kills the NE (under the kill switch a jetsam-kill lands in the
        //      T-QA-23 crash-gap). The 75% split is PROVISIONAL: the profiled peak-under-load
        //      number is the oldest-iOS-17 device run under T-CFG-16, which replaces it. A
        //      degenerate reading (0 or implausibly small: unsupported context, or already near
        //      the ceiling) skips the limit rather than strangling throughput with a tight one.
        setupOpts.oomKillerEnabled = true
        // os_proc_available_memory() (os/proc.h) is iOS/tvOS/watchOS-only. iOS derives the ceiling
        // from live jetsam headroom (rationale above); a macOS system extension has no comparable
        // jetsam budget and the symbol is unavailable there, so skip the explicit limit and rely on
        // oomKillerEnabled alone.
#if os(iOS)
        let availableBytes = os_proc_available_memory()
        if availableBytes > (8 << 20) {  // 8 MiB floor: below this, treat the reading as unusable
            setupOpts.oomMemoryLimit = Int64(availableBytes) * 3 / 4
        }
#endif

        var setupErr: NSError?
        LibboxSetup(setupOpts, &setupErr)
        if let e = setupErr { throw e }

        var createErr: NSError?
        let server = LibboxNewCommandServer(iface, iface, &createErr)
        if let e = createErr { throw e }
        guard let server else {
            throw NSError(domain: singBoxErrorDomain, code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "LibboxNewCommandServer returned nil"])
        }
        // Lifecycle guard 2: a stop() during setup already detached + reset the published
        // platformInterface and saw commandServer == nil. The local server was never published
        // or started, so close() alone releases it — nothing stop() touched is double-freed.
        lock.lock()
        if stopped {
            lock.unlock()
            server.close()
            return false
        }
        commandServer = server
        lock.unlock()

        // Lifecycle guards 3+4: from here the server IS published — a racing stop() detaches
        // it and owns the full teardown (closeService/reset/close). On abort start() must NOT
        // touch the server again (a second close() would re-close the Go subscriber channels:
        // panic); a plain return is the correct local cleanup.
        lock.lock()
        if stopped { lock.unlock(); return false }
        lock.unlock()
        try server.start()

        lock.lock()
        if stopped { lock.unlock(); return false }
        lock.unlock()
        try server.startOrReloadService(configJSON, options: LibboxOverrideOptions())
        return true
    }

    // Stops the engine and releases all libbox resources.
    func stop() {
        // Detach the pointers under the lock, then tear down on the locals OUTSIDE it
        // (never hold the lock across libbox calls). Swapping to locals also makes stop()
        // idempotent — a re-entrant stop (e.g. serviceStop → cancelTunnelWithError) sees
        // nil and no-ops instead of double-closing. Latching `stopped` in the same critical
        // section makes a mid-flight start() abort at its next guard (F-1/F-4): whatever
        // stop() detaches here it tears down; whatever was not yet published stays local
        // to start(), which cleans it up itself.
        lock.lock()
        stopped = true
        let server = commandServer
        let iface  = platformInterface
        commandServer = nil
        platformInterface = nil
        lock.unlock()

        tearDown(server, iface)
    }

    // T-ROUTE-8: stop()'s teardown for a start that threw, WITHOUT the latch, so this object can be
    // started once more — PacketTunnelProvider's retry without the Smart merge. The provider's
    // `singBox` keeps pointing at this object, so a stopTunnel that lands at any point still reaches
    // the one latch: it wins, and the retry's start() aborts at its next guard as a first start does.
    // False — nothing torn down, nothing to retry — when stop() already won: the session is ending,
    // and stop() owns its teardown.
    //
    // WHY A SECOND START IN THIS PROCESS IS SAFE (read in the pinned 1.14.1 tree with the morke.2
    // patch applied, 2026-10-26). Process-global libbox state is set again, not accumulated:
    // LibboxSetup reassigns its option globals, its MkdirAll is idempotent, and its crash log is
    // re-pointed (debug.SetCrashOutput replaces an earlier call; the log of a failed start is empty
    // and is not archived); the OOM killer's memory-pressure source is reference-counted across
    // service instances; log.SetStdLogger is replaced by the next instance. Everything else is per
    // command server — a new context with its own registries (baseContext), its own gRPC listener on
    // <basePath>/command.sock, which Start() removes before it listens, its own OOM recorder — or per
    // platform interface, which start() makes new. The TUN fd libbox hands sing-tun is a dup of the
    // provider's packetFlow descriptor (platformInterfaceWrapper.OpenInterface), so closing an engine
    // instance never closes the provider's. sing-box's own reload (StartOrReloadService) builds a new
    // engine instance in the same process by design. A list the engine refuses fails box.New at
    // router.Initialize, before any inbound is created, the platform interface is initialised or
    // openTun runs: nothing was started, and CloseService finds nothing to close. Not measured: the
    // oomMemoryLimit start() derives again from os_proc_available_memory() may read a little lower
    // after a failed start.
    func discardFailedStart() -> Bool {
        lock.lock()
        if stopped {
            lock.unlock()
            return false
        }
        let server = commandServer
        let iface  = platformInterface
        commandServer = nil
        platformInterface = nil
        lock.unlock()

        tearDown(server, iface)
        return true
    }

    // The teardown both paths share, on locals detached under the lock — never called holding it.
    private func tearDown(_ server: LibboxCommandServer?, _ iface: ExtensionPlatformInterface?) {
        try? server?.closeService()
        iface?.reset()          // must run before close() — see ExtensionPlatformInterface.h
        server?.close()
    }

    // FileManager only: MorkeTunnel takes no new dependency for this. Logged as numbers and the fact
    // of removal only — never the file's content or size.
    private func removeStaleConfigSnapshot(in container: URL) {
        do {
            try FileManager.default.removeItem(at: container.appendingPathComponent("configuration.json"))
            log.notice("start: stale configuration snapshot removed")
        } catch CocoaError.fileNoSuchFile {
            // The normal case from the first morke.2 start on: nothing to remove.
        } catch {
            if let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)
                .flatMap({ $0.domain == NSPOSIXErrorDomain ? $0.code : nil }) {
                log.error("start: stale configuration snapshot delete failed, errno=\(code, privacy: .public)")
            } else {
                log.error("start: stale configuration snapshot delete failed, errno unavailable")
            }
        }
    }

#if os(macOS)
    // T-MAC-15: removes the engine's workspace — AppGroup.removeEngineWorkspace's list — from THIS
    // process's App-Group container. macOS only: the system extension runs as root, so its container is
    // root's and the app's TunnelWorkspace.wipe() never reaches it (T-MAC-14); on iOS the app and the
    // appex share one container and the wipe already works. Called before LibboxSetup on every start
    // and from stopTunnel once the engine is stopped, so the engine's files live only while a tunnel
    // runs. Synchronous local file removal only, the same class of work as the stop path's other
    // App-Group writes: no retry, no wait, no throw. Logged as the item's name from the list and its
    // errno, never a path read from disk or anything about the config.
    static func scrubWorkspace(in container: URL? = nil, phase: String) {
        guard let container = container ?? FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.appGroupID
        ) else {
            log.error("\(phase, privacy: .public): engine workspace scrub skipped, App Group container not found")
            return
        }
        let failures = AppGroup.removeEngineWorkspace(in: container)
        guard !failures.isEmpty else {
            log.notice("\(phase, privacy: .public): engine workspace scrubbed")
            return
        }
        for failure in failures {
            if let code = failure.errno {
                log.error("\(phase, privacy: .public): engine workspace \(failure.item, privacy: .public) delete failed, errno=\(code, privacy: .public)")
            } else {
                log.error("\(phase, privacy: .public): engine workspace \(failure.item, privacy: .public) delete failed, errno unavailable")
            }
        }
    }

#endif
    // Forward NEPacketTunnelProvider sleep/wake to libbox so it can pause keepalives.
    // Read the pointer under the lock, then call libbox on the local copy outside it.
    func pause() {
        lock.lock(); let server = commandServer; lock.unlock()
        server?.pause()
    }
    func wake() {
        lock.lock(); let server = commandServer; lock.unlock()
        server?.wake()
    }
    // libbox 1.14.4: on iOS `pause()` sets the engine's device pause and `wake()` no longer ends it
    // (experimental/libbox/command_server.go — upstream's own client ends it from the screen state,
    // ScreenStateObserver → `wakeNow`). This ends it unconditionally. Same locking as above.
    func wakeNow() {
        lock.lock(); let server = commandServer; lock.unlock()
        server?.wakeNow()
    }
}
