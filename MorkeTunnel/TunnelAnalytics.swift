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

import Foundation
import Libbox
import OSLog
import os
import MorkeShared

// Same subsystem and category as PacketTunnelProvider, so a session reads as one timeline.
private let log = Logger(subsystem: MorkeLog.subsystem, category: "tunnel")

// MARK: - TunnelAnalyticsRecorder (T-DESIGN-24 · P9g)
//
// The tunnel's half of Home's analytics: `analytics-tunnel.json`, which only this process can write —
// a session that runs while the app is asleep is seen by nobody else. One recorder per start, created
// with it and stopped with it, so a start that never came up leaves nothing behind. iOS only: this
// file belongs to the iOS target alone, and PacketTunnelProvider's property says why.
//
// WHAT IT WRITES, AND WHEN — counters, buckets and days, never a row (the line is
// ConnectionMetricsClient.swift's header, § THE PRIVACY LINE):
//   • `tunnelStarts` +1 when a start CAME UP — `begin()`, called just before `completion(nil)`.
//   • `protectedSeconds` at a checkpoint every five minutes while up, at `sleep`, and at `stopTunnel`:
//     the MONOTONIC time since the last write, placed by the wall clock and split across buckets and
//     local days (AnalyticsDocument.addProtectedInterval).
//   • `trafficBytes` at the same moments: the bytes the engine moved through the proxy since the last
//     write (EngineStatusSubscription below), split by time like the seconds — written even when it is
//     0, because its presence means "measured".
//   • `killSwitchBlocks` +1, counter and the bucket at the stop, when the stop is a drop under
//     includeAllNetworks (morke_stop_is_kill_switch_block, MorkeTunnelNetHelpers.c — the set is there).
//
// NEVER A COPY OF THE DOCUMENT. `delta` holds only what accrued since the last successful write; each
// write reads the file, adds the delta and replaces the file only if it is still there
// (AppGroup.foldTunnelAnalytics). The app's reset deletes the document, so a held copy would write the
// cleared numbers back; a delta that straddles a reset is dropped instead.
//
// WHOSE DOCUMENT (P9h): the account container the app's pointer names when the start comes up, read
// ONCE in `begin()` and kept for the whole session (AppGroup.tunnelAnalyticsDirectory) — a sign-out or
// a second account signing in mid-session cannot split it. With no pointer the session writes
// `pending/`, which the app adopts; there a document that disappears was adopted, not reset, so what
// accrued since the last write starts a new pending document rather than being dropped.
//
// TIME: the length of every interval is ContinuousClock — monotonic and running through system sleep,
// which is right for a tunnel that stays up overnight; a reboot resets that axis but also ends this
// process, so no interval can span one. An instant on it is not a timestamp and never leaves memory.
// The mark advances by exactly the whole seconds counted, so the fraction carries into the next
// interval and a session's sum is exact to under a second. `Date()` only PLACES the interval.
//
// TRAFFIC is libbox's own running totals, `uplinkTotal` / `downlinkTotal` — payload through the proxy,
// counted by the engine's traffic manager on every connection it carries, the same whatever the TUN
// stack. They arrive only as a STATUS stream from the command server this process already runs; see
// EngineStatusSubscription below for what is read, how often, and what it costs. A total that goes down
// is a new engine, counted from zero (morke_counter_delta).
// WHY NOT THE UTUN'S OWN BYTE COUNTERS, which P9g read first: measured on NYFB / iOS 27.0 on 2026-10-06,
// a 104 857 600-byte download with the Kill Switch OFF read as 109 345 792 in + 108 605 440 out —
// 2.079× the file. Under the `system` TUN stack sing-tun hands TCP to the kernel's own stack by writing
// every packet it reads from the utun back into it, rewritten to a local listener, both ways, so each
// TCP byte crosses the interface twice; under gVisor (Kill Switch ON) it crosses once, and UDP once on
// both. No correction recovers the payload from those counters, so they were removed (P9gb).
//
// THREADING: everything below `queue` is read and written on it only. begin() hops onto it; sleep and
// stop wait for it — bounded by one small write, the only work it ever does (the status client dials on
// a queue of its own). The timer is a dispatch timer on the uptime clock: it does not fire while the
// device sleeps and never wakes it, and its leeway lets the system coalesce it with other wake-ups.
final class TunnelAnalyticsRecorder: @unchecked Sendable {

    // Five minutes — the ledger's narrowest bucket, so a live session fills the chart as it runs.
    static let checkpointInterval = DispatchTimeInterval.seconds(300)
    static let checkpointLeeway = DispatchTimeInterval.seconds(60)

    private enum Moment: String {
        case begin, checkpoint, sleep, stop
    }

    private let queue = DispatchQueue(label: "tech.twodice.morke.tunnel.analytics")
    private let status = EngineStatusSubscription()
    private var began = false
    private var stopped = false
    private var mark: ContinuousClock.Instant?
    // The engine's totals at the last write. Zero at the start: the engine's totals start there too, so
    // whatever it carried before the first status message belongs to this session.
    private var trafficBaseline: (up: UInt64, down: UInt64) = (0, 0)
    private var delta: AnalyticsDocument?
    // "This session has written the document": an absent document after that was reset, not new.
    private var documentExpected = false
    // This session's container, resolved once in begin(). nil: the App-Group container could not be
    // resolved, and nothing is written.
    private var directory: AppGroup.TunnelAnalyticsDirectory?
    private var timer: DispatchSourceTimer?

    // The start came up. Asynchronous, so it never delays `completion(nil)`; a stop that got here first
    // has latched `stopped`, and a start it overtook counts nothing.
    func begin() {
        queue.async { [self] in
            guard !stopped, !began else { return }
            began = true
            let wall = Date()
            mark = ContinuousClock.now
            directory = AppGroup.tunnelAnalyticsDirectory()
            status.open()
            var pending = delta ?? AnalyticsDocument(since: wall.timeIntervalSince1970)
            pending.add(1, to: AnalyticsLedger.Key.tunnelStarts, at: wall, calendar: AnalyticsLedger.calendar())
            delta = pending
            // Which KIND of container only — never its name, which is derived from the account id.
            let target = directory.map { $0.isPending ? "pending" : "account" } ?? "none (no App-Group container)"
            log.notice("analytics: session began — tunnelStarts +1, container \(target, privacy: .public) (P9h)")
            write(.begin)
            startTimer()
        }
    }

    // The device is about to sleep: what accrued is written before it does.
    func checkpointBeforeSleep() {
        queue.sync { fold(.sleep) }
    }

    // stopTunnel's fold — one read, one add, one conditional write of a few KB, on the deadline the stop
    // runs on — and then the status client's close. Called BEFORE the engine stops, so the last total
    // is the engine's and the client goes before the server does. `reason` is the NEProviderStopReason
    // raw value; only a start that came up can be blocked.
    func stop(reason: Int, includeAllNetworks: Bool) {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            timer = nil
            guard began else { return }
            let block = morke_stop_is_kill_switch_block(includeAllNetworks, reason)
            log.notice("analytics: stop reason \(reason, privacy: .public) includeAllNetworks=\(includeAllNetworks, privacy: .public) → killSwitchBlock=\(block ? 1 : 0, privacy: .public)")
            fold(.stop, killSwitchBlock: block)
            mark = nil
            status.close()
        }
    }

    // MARK: - On `queue`

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.checkpointInterval,
            repeating: Self.checkpointInterval,
            leeway: Self.checkpointLeeway
        )
        timer.setEventHandler { [weak self] in self?.fold(.checkpoint) }
        timer.resume()
        self.timer = timer
    }

    private func fold(_ moment: Moment, killSwitchBlock: Bool = false) {
        guard let mark else { return }
        let elapsed = ContinuousClock.now - mark
        let wall = Date()
        let seconds = max(elapsed.components.seconds, 0)
        self.mark = mark.advanced(by: .seconds(seconds))
        let bytes = takeTrafficDelta()
        let calendar = AnalyticsLedger.calendar()
        var pending = delta ?? AnalyticsDocument(since: wall.timeIntervalSince1970 - TimeInterval(seconds))
        pending.addProtectedInterval(
            seconds: seconds,
            trafficBytes: bytes.map { AnalyticsDocument.saturatingSum(Int64(clamping: $0.up), Int64(clamping: $0.down)) },
            endingAt: wall,
            calendar: calendar
        )
        if killSwitchBlock {
            let key = AnalyticsLedger.Key.killSwitchBlocks
            pending.add(1, to: key, bucket: key, at: wall, calendar: calendar)
        }
        delta = pending
        // The byte values reach the log in Debug only; Release says measured, without them (T-INFRA-44).
        if let bytes {
            #if DEBUG
            log.notice("analytics: \(moment.rawValue, privacy: .public) — seconds=\(seconds, privacy: .public) trafficUp=\(bytes.up, privacy: .public) trafficDown=\(bytes.down, privacy: .public)")
            #else
            _ = bytes
            log.notice("analytics: \(moment.rawValue, privacy: .public) — seconds=\(seconds, privacy: .public) traffic measured")
            #endif
        } else {
            log.notice("analytics: \(moment.rawValue, privacy: .public) — seconds=\(seconds, privacy: .public) traffic unmeasured")
        }
        write(moment)
    }

    private func write(_ moment: Moment) {
        guard let pending = delta, let directory else { return }
        var fold = AppGroup.foldTunnelAnalytics(
            pending, documentExpected: documentExpected && !directory.isPending,
            in: directory.url, now: Date(), calendar: AnalyticsLedger.calendar()
        )
        if fold == .resetDetected, directory.isPending {
            // Adopted between this write's read and its rename: everything up to the last write went
            // with it, so the delta alone starts the next pending document.
            fold = AppGroup.foldTunnelAnalytics(
                pending, documentExpected: false, in: directory.url, now: Date(), calendar: AnalyticsLedger.calendar()
            )
        }
        switch fold {
        case .written(let document):
            delta = nil
            documentExpected = true
            log.notice("analytics: \(moment.rawValue, privacy: .public) written")
            #if DEBUG
            logReadBack(document)
            #endif
        case .deferred:
            log.error("analytics: \(moment.rawValue, privacy: .public) deferred — kept in memory, offered again at the next write")
        case .resetDetected:
            delta = nil
            documentExpected = false
            log.notice("analytics: \(moment.rawValue, privacy: .public) — the document was reset, what accrued since the last write is dropped")
        }
    }

    // The bytes since the last write, or nil when this interval cannot be measured — no status message
    // yet, or one saying the engine has no traffic manager. Unmeasured keeps the baseline, so the next
    // measured interval carries these bytes rather than losing them.
    private func takeTrafficDelta() -> (up: UInt64, down: UInt64)? {
        guard let totals = status.totals else { return nil }
        let current = (up: UInt64(clamping: totals.up), down: UInt64(clamping: totals.down))
        defer { trafficBaseline = current }
        return (morke_counter_delta(trafficBaseline.up, current.up),
                morke_counter_delta(trafficBaseline.down, current.down))
    }

    #if DEBUG
    // The document as written, summed, in one line — how a device check reads a file `devicectl` cannot
    // (on iOS 27 it copies nothing from an App Group container's root). Debug builds only; counts only.
    private func logReadBack(_ document: AnalyticsDocument) {
        typealias Key = AnalyticsLedger.Key
        func bucketed(_ key: String) -> Int64 {
            document.buckets.values.reduce(0) { AnalyticsDocument.saturatingSum($0, $1[key] ?? 0) }
        }
        let today = AnalyticsLedger.dayKey(for: Date(), calendar: AnalyticsLedger.calendar())
        let protectedToday = document.days[today]?[Key.protectedSeconds] ?? 0
        let traffic = document.counters[Key.trafficBytes].map { String($0) } ?? "absent"
        log.notice("analytics: read-back — protectedSeconds=\(document.counters[Key.protectedSeconds] ?? 0, privacy: .public) bucketed=\(bucketed(Key.protectedSeconds), privacy: .public) today=\(protectedToday, privacy: .public) trafficBytes=\(traffic, privacy: .public) bucketedTraffic=\(bucketed(Key.trafficBytes), privacy: .public) killSwitchBlocks=\(document.counters[Key.killSwitchBlocks] ?? 0, privacy: .public) bucketedBlocks=\(bucketed(Key.killSwitchBlocks), privacy: .public) tunnelStarts=\(document.counters[Key.tunnelStarts] ?? 0, privacy: .public)")
    }
    #endif
}

// MARK: - EngineStatusSubscription (P9gb)
//
// The engine's own traffic totals. The command server this process already runs (SingBoxTunnel) serves
// them as a STATUS stream; this opens ONE LibboxCommandClient for the session, subscribed to the status
// command and NOTHING else — never connections or logs, which carry destinations and domains. Of each
// message it reads `trafficAvailable`, `uplinkTotal` and `downlinkTotal`, and keeps the latest two
// integers in memory. Nothing else in the message is read, and nothing leaves the process: the client
// dials the server's unix socket in our own container.
//
// INTERVAL — 10 s. The server sends one message the moment the stream opens, then one per interval
// (libbox 1.14.1 daemon/started_service.go SubscribeStatus), so any fold reads a total at most 10 s
// old. At a checkpoint that only moves bytes into the next interval; at the STOP it is a loss — the
// engine's last ≤ 10 s are never counted, since the next engine starts from zero. Undercount, never
// overcount. Longer would lose more at every stop; shorter buys freshness the 5-minute chart cannot
// show, at one status read per tick. Its memory and CPU are what P9gb's device gate measures.
//
// CONNECT CAN BLOCK: a handler-bound client dials with up to ten retries, ~3.3 s at worst
// (command_client.go dialWithRetry), so it dials on a queue of its own, never on the recorder's, which
// stopTunnel waits on. CLOSE: once connected, Disconnect is a context cancel and a socket close, done in
// place before the engine stops. While a dial is still running Disconnect would wait on the client's
// mutex, so the close is left to the dial's own completion instead. The server stops with grpc's
// non-graceful Stop, so a client still attached when the engine goes holds nothing up.
final class EngineStatusSubscription: NSObject, LibboxCommandClientHandlerProtocol, @unchecked Sendable {

    struct Totals: Sendable {
        var up: Int64
        var down: Int64
    }

    // Nanoseconds: libbox reads it as a Go time.Duration.
    static let statusInterval: Int64 = 10 * 1_000_000_000

    private enum Connection { case idle, dialing, connected, closeRequested, closed }

    private let latest = OSAllocatedUnfairLock<Totals?>(initialState: nil)
    private let connection = OSAllocatedUnfairLock(initialState: Connection.idle)
    private let dialQueue = DispatchQueue(label: "tech.twodice.morke.tunnel.analytics.status")
    // Set by open() and taken by close(), both on the recorder's queue.
    private var client: LibboxCommandClient?

    // The latest totals, or nil while there is no message or the engine reports no traffic manager.
    var totals: Totals? { latest.withLock { $0 } }

    func open() {
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        options.statusInterval = Self.statusInterval
        guard let client = LibboxNewCommandClient(self, options) else {
            log.error("analytics: status client not created — traffic unmeasured this session")
            return
        }
        self.client = client
        connection.withLock { $0 = .dialing }
        // gobind marks nothing Sendable, but the Go client guards its own state with a mutex
        // (command_client.go clientMutex); the hand-off is this one closure, and `connection` decides
        // which side disconnects it.
        nonisolated(unsafe) let dialing = client
        dialQueue.async { [self] in
            let dialed: Bool
            do {
                try dialing.connect()
                dialed = true
            } catch {
                dialed = false
            }
            let closeNow = connection.withLock { (state: inout Connection) -> Bool in
                let requested = state == .closeRequested
                state = dialed && !requested ? .connected : .closed
                return dialed && requested
            }
            if !dialed {
                log.error("analytics: status client could not connect — traffic unmeasured this session")
            }
            if closeNow { disconnect(dialing) }
        }
    }

    func close() {
        guard let client else { return }
        self.client = nil
        let connected = connection.withLock { (state: inout Connection) -> Bool in
            switch state {
            case .connected:
                state = .closed
                return true
            case .dialing:
                state = .closeRequested
                return false
            case .idle, .closeRequested, .closed:
                state = .closed
                return false
            }
        }
        if connected { disconnect(client) }
    }

    private func disconnect(_ client: LibboxCommandClient) {
        do {
            try client.disconnect()
        } catch {
            log.error("analytics: status client disconnect failed")
        }
    }

    // MARK: LibboxCommandClientHandler — called on the engine's goroutines

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let message else { return }
        let totals = message.trafficAvailable ? Totals(up: message.uplinkTotal, down: message.downlinkTotal) : nil
        latest.withLock { $0 = totals }
    }

    func connected() {
        log.notice("analytics: status subscription connected (interval 10 s)")
    }

    // The message is the stream's error text; it is not logged. With no stream the last totals would read
    // as "nothing moved" at every later fold, so they go: what follows is unmeasured, which is not zero.
    // At a normal stop this runs after the last fold has read them.
    func disconnected(_ message: String?) {
        latest.withLock { $0 = nil }
        log.notice("analytics: status subscription ended")
    }

    // Never subscribed to, so never called; required by the protocol.
    func clearLogs() {}
    func setDefaultLogLevel(_ level: Int32) {}
    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {}
    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {}
    func writeOutbounds(_ message: (any LibboxOutboundGroupItemIteratorProtocol)?) {}
    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}
    func write(_ events: LibboxConnectionEvents?) {}
}
