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

// MARK: - AnalyticsLedger (T-DESIGN-24 · P9a, 2026-10-06)
//
// The on-disk shape of the user's own numbers — the store under Home's analytics block. It exists
// because the v1 files (`connection-stats.json`, `protected-time-totals.json`) were one property per
// counter with synthesized `Codable`: synthesized decoding ignores property defaults, so ONE added
// non-optional field would make every existing file fail to decode, and both readers turned that
// failure into zeros and wrote them back. The maintainer's rule this file is built to keep: adding
// or removing anything later must never reset a user's progress because of our mistake.
//
// HOW THE SHAPE KEEPS IT:
//   • NAMED COUNTERS IN MAPS, never a stored property per counter. Adding or retiring a counter is a
//     key, not a decode failure, and a key this build does not know rides through a
//     read-modify-write untouched because the whole map is carried. Every key is named ONCE, in
//     `AnalyticsLedger.Key` below.
//   • HAND-WRITTEN, LENIENT DECODING: every field is `decodeIfPresent` with a default. A field that is
//     ABSENT takes its default; a field that is PRESENT but malformed fails the decode, and the
//     document reads as `.unreadable` — never as zeros.
//   • `schema`: a document whose schema is newer than this build is read and shown but NEVER written
//     (`write` refuses it). A new TOP-LEVEL field whose meaning an older writer must not drop bumps
//     `schema`; a new counter does not, it is only a key.
//   • SAFE IO: a read answers absent / document / unreadable / unavailable. Unreadable (the bytes are
//     there and do not decode) is moved to `<name>.unreadable` before anything is written in its
//     place, and an occupied slot is never overwritten. Unavailable (the file exists and could not be
//     READ — on iOS, a file protected until first unlock read before it) is never written over and
//     never moved: it is fine, just not readable yet.
//   • `id` is a UUID made once per document — what a future cross-device read (Mac · iPad · TV)
//     merges by. `merging(_:)` is that merge, built now and exact; no sync is built.
//
// ONE WRITER PER DOCUMENT, as with v1: `analytics-app.json` is the app's (ConnectionMetricsStore),
// `analytics-tunnel.json` is the Packet Tunnel's (from P9g on). Neither process writes the other's
// file; the app's reset and an account's deletion delete both.
//
// ONE CONTAINER PER ACCOUNT (P9h, decided 2026-10-06): both documents live in
// `Library/Application Support/Analytics/<name>/` inside the App-Group container, one directory per
// account, where `<name>` is the hex SHA-256 of the account id (made on the app side — the raw id is
// never on disk). One pointer file beside them, `current`, names the container of the account whose
// session is established; the tunnel reads it once per session and never builds a path from anything
// but a validated name. With no pointer the tunnel writes `pending/`, which the app adopts. Only the
// app creates an account's directory (when it writes the pointer), so nothing the tunnel does can
// bring back a container an account deletion removed. See "Containers" below.
//
// BOUNDED BY CONSTRUCTION — the privacy line, which ConnectionMetricsClient.swift's header states in
// full: counters, at most `maxBuckets` time buckets whose width doubles as history grows, the last
// `dayCount` local days, and (P57) the chart's two small rings — at most `minuteSlots` 5-minute slots
// and `hourSlots` local hours, see "The chart's slots" below. Nothing per session, no event time, no
// node, no reason text. Foundation only: this file ships inside the Network Extension, whose memory
// budget is the tightest we have.

public nonisolated enum AnalyticsLedger {

    public static let appDocumentName = "analytics-app.json"
    public static let tunnelDocumentName = "analytics-tunnel.json"
    // Where the tunnel's writer stages a document before its conditional rename
    // (AppGroup.replaceTunnelDocument). Named here so the writer and the app's reset name it once.
    public static let tunnelStagingName = tunnelDocumentName + ".writing"
    // Where an unreadable document is moved, beside it: `<name>.unreadable`. One slot per name.
    public static let unreadableSuffix = ".unreadable"

    // Bucket width = baseBucketWidth × 2ⁿ seconds, starts aligned to multiples of the width since
    // 1970. 5 minutes at the very start, then wider — the chart is dense, never sparse.
    public static let baseBucketWidth: Int64 = 300
    // The FIXED maximum: the buckets between the earliest and the latest never number more than this
    // (empty ones are not stored, so fewer are). An add that would need one more doubles the width.
    public static let maxBuckets: Int64 = 64
    // The local-day ring: the last 90 calendar days, older keys pruned on every write.
    public static let dayCount = 90

    // MARK: - The chart's slots (P57, the maintainer's rulings of 2026-11-05)
    //
    // The chart draws ONE unit at a time, active periods only, newest on the right, at most
    // `chartSlots` bars: 5-minute bars while the measured history is in its first hour, hour bars while
    // its active hours fit the slots, day bars after. The doubling buckets above cannot give that —
    // after a gap their width covers the gap — so the document keeps, beside them, what each unit needs:
    //   • `minutes`: sums per 5-minute slot of the local hour, only the slots of the hour that ends
    //     with the latest active one (at most `minuteSlots`);
    //   • `hours`: sums per local hour, only the latest `hourSlots` active hours — one more than the
    //     chart's slots, so "more than fit" is known without keeping more;
    //   • `days`: the ring above, which carries traffic and the red keys too from P57 on.
    // Each is a sum over a slot of a fixed grid, as a bucket is, and each lies inside the day ring's 90
    // days (pruned with it). Every write that names a bucket key adds to all three, and a protected
    // interval is cut so each share lies in one day, and in one hour and one 5-minute slot wherever
    // those rings could keep it (`slotShares`) — so the three agree to the byte where they overlap,
    // which is what the snapshot's choice of unit compares (AnalyticsSnapshot.make).
    public static let chartSlots = 26
    public static let minuteWidth: Int64 = 300
    public static let minuteSlots: Int64 = 12
    public static let hourSlots = chartSlots + 1

    // Bucket starts outside ±2⁴⁰ s (≈ 34 800 years) are refused rather than stored. Only a broken
    // clock or a hand-edited file produces one, and accepting it would let one value force the
    // width to the end of Int64. The count still lands in the counter total — the baseline — so
    // nothing is lost, only a bar.
    static let bucketRange: ClosedRange<Int64> = -(1 << 40)...(1 << 40)

    // MARK: - Keys — every key in either document, named once

    public enum Key {
        // ── analytics-app.json (ConnectionMetricsStore) ──────────────────────────────────────────
        // Setup-time bands: `setupPrefix` + `SetupTimeBucket.rawValue`. The prefix is what the v1
        // migration uses, so a band the v1 file had and this build lost still keeps a key.
        public static let setupPrefix = "setup."
        public static let setupUnder1s = setupPrefix + "under1s"
        public static let setupOneToTwo = setupPrefix + "oneToTwo"
        public static let setupTwoToFive = setupPrefix + "twoToFive"
        public static let setupFiveToTen = setupPrefix + "fiveToTen"
        public static let setupTenPlus = setupPrefix + "tenPlus"
        // Connect failures by coarse reason: `connectFailurePrefix` + `ConnectFailureReason.rawValue`.
        // "Failed" on screen is the sum over the PREFIX, so a reason retired later still counts.
        public static let connectFailurePrefix = "connectFailure."
        public static let connectFailureConfigFetch = connectFailurePrefix + "configFetch"
        public static let connectFailureTunnelStart = connectFailurePrefix + "tunnelStart"
        public static let connectFailureOther = connectFailurePrefix + "other"
        public static let connectSuccesses = "connectSuccesses"
        public static let configFetchSuccesses = "configFetchSuccesses"
        public static let configFetchFailures = "configFetchFailures"
        public static let reconnects = "reconnects"
        // Bucket key: connect failures per time bucket (the red bars, with `killSwitchBlocks`).
        public static let failures = "failures"

        // ── analytics-tunnel.json (PacketTunnelProvider, from P9g) ───────────────────────────────
        // Counter, bucket and day key: seconds of protection.
        public static let protectedSeconds = "protectedSeconds"
        // Counter and bucket key: bytes through the tunnel, up and down summed. Its PRESENCE in a
        // document's counters (even at 0) is what "traffic has been measured" means — absent is
        // "No data", which is not zero.
        public static let trafficBytes = "trafficBytes"
        // Counter: tunnel starts that came up ("Succeeded" on screen).
        public static let tunnelStarts = "tunnelStarts"
        // Counter and bucket key: connections the Kill Switch blocked (the red bars, with `failures`).
        public static let killSwitchBlocks = "killSwitchBlocks"
    }

    // MARK: - Reading

    // The raw outcome of reading one file, before any decoding.
    public enum FileRead: Sendable, Equatable {
        case absent
        case data(Data)
        // The file EXISTS and could not be read. Never written over, never moved aside.
        case unavailable
    }

    public enum ReadResult: Sendable, Equatable {
        case absent
        case document(AnalyticsDocument)
        // The bytes are there and are not a document. The caller moves them aside before writing.
        case unreadable
        // See FileRead.unavailable.
        case unavailable
    }

    public static func url(named name: String, in container: URL) -> URL {
        container.appendingPathComponent(name)
    }

    // MARK: - Containers (P9h)
    //
    // `appGroup` is always the App-Group container's root; a "container" here is one account's
    // directory under it. Library/Application Support rather than the root: `devicectl` can read
    // `Library` on iOS 27 and not the root, and Application Support is in the device backup, which
    // the numbers are meant to be (Caches is not).

    public static let pointerName = "current"
    public static let pendingName = "pending"

    public static func analyticsDirectory(in appGroup: URL) -> URL {
        appGroup
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Analytics", isDirectory: true)
    }

    // Callers pass a name `isContainerName` accepted, or `pendingName` — nothing else.
    public static func containerDirectory(named name: String, in appGroup: URL) -> URL {
        analyticsDirectory(in: appGroup).appendingPathComponent(name, isDirectory: true)
    }

    // A container name is exactly 64 lowercase hex digits — a SHA-256 — so it can carry no path
    // separator, no "..", and never equals `pendingName`.
    public static func isContainerName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
        }
    }

    public enum Pointer: Sendable, Equatable {
        case absent
        // A validated container name.
        case current(String)
        // The file is there and is not a container name. Refused: no path is built from it.
        case malformed
        // See FileRead.unavailable.
        case unavailable
    }

    public static func readPointer(in appGroup: URL) -> Pointer {
        switch readFile(named: pointerName, in: analyticsDirectory(in: appGroup)) {
        case .absent:
            return .absent
        case .unavailable:
            return .unavailable
        case .data(let data):
            guard let name = String(data: data, encoding: .utf8), isContainerName(name) else { return .malformed }
            return .current(name)
        }
    }

    // The app's, and only the app's: on a session established (the name) and on sign-out or account
    // deletion (the clear). Throws so the caller can act on a pointer that may still name someone else.
    public static func writePointer(_ name: String, in appGroup: URL) throws {
        try Data(name.utf8).write(to: url(named: pointerName, in: analyticsDirectory(in: appGroup)), options: writeOptions)
    }

    public static func clearPointer(in appGroup: URL) throws {
        do {
            try FileManager.default.removeItem(at: url(named: pointerName, in: analyticsDirectory(in: appGroup)))
        } catch CocoaError.fileNoSuchFile {
            // Already clear.
        }
    }

    public static func readFile(named name: String, in container: URL) -> FileRead {
        let url = url(named: name, in: container)
        do {
            return .data(try Data(contentsOf: url))
        } catch {
            // Absent is the one failure that means "nothing here". Anything else with a file present
            // (data protection before first unlock, a directory in the way) is not a verdict on the
            // contents and must not be treated as one.
            return FileManager.default.fileExists(atPath: url.path) ? .unavailable : .absent
        }
    }

    // `calendar` places a pre-P57 document's buckets in local hours and days when it is migrated (see
    // AnalyticsDocument.migrateLegacyBuckets); every writer uses `calendar()`, the default.
    public static func read(named name: String, in container: URL, calendar: Calendar = calendar()) -> ReadResult {
        switch readFile(named: name, in: container) {
        case .absent:
            return .absent
        case .unavailable:
            return .unavailable
        case .data(let data):
            do {
                return .document(try decoder(calendar: calendar).decode(AnalyticsDocument.self, from: data))
            } catch {
                return .unreadable
            }
        }
    }

    // A decoder that hands `calendar` to the migration of a pre-P57 document.
    public static func decoder(calendar: Calendar) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[calendarInfoKey] = calendar
        return decoder
    }

    static let calendarInfoKey = CodingUserInfoKey(rawValue: "tech.twodice.morke.analytics.calendar")!

    // MARK: - Writing

    // Writes `document` and returns it AS WRITTEN (revision + 1, the day ring pruned), or nil when it
    // was refused or failed — the caller keeps its in-memory copy and tries again at the next write.
    // Refused: a document whose schema is newer than this build. Atomic; on iOS protected until the
    // first unlock after boot, because the tunnel writes while the phone is locked.
    @discardableResult
    public static func write(
        _ document: AnalyticsDocument,
        named name: String,
        in container: URL,
        now: Date,
        calendar: Calendar
    ) -> AnalyticsDocument? {
        guard document.isWritable else { return nil }
        var written = document
        written.revision = AnalyticsDocument.saturatingSum(written.revision, 1)
        written.pruneDays(now: now, calendar: calendar)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(written)
            try data.write(to: url(named: name, in: container), options: writeOptions)
            return written
        } catch {
            return nil
        }
    }

    #if os(iOS)
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
    static let writeOptions: Data.WritingOptions = [.atomic]
    #endif

    // Moves an unreadable file to `<name>.unreadable`. Returns false — and moves NOTHING — when the
    // slot is already occupied: the earlier unreadable bytes are never overwritten, and the caller
    // must then not write in the file's place either.
    public static func moveAside(named name: String, in container: URL) -> Bool {
        let slot = url(named: name + unreadableSuffix, in: container)
        guard !FileManager.default.fileExists(atPath: slot.path) else { return false }
        do {
            // moveItem itself refuses an existing destination, so the check above is not the only
            // guard against overwriting the slot.
            try FileManager.default.moveItem(at: url(named: name, in: container), to: slot)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Local days

    // Gregorian in the given time zone — never the user's calendar setting, so a day key is always a
    // Gregorian "yyyy-MM-dd" whatever calendar the device displays.
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return pad(parts.year ?? 0, 4) + "-" + pad(parts.month ?? 0, 2) + "-" + pad(parts.day ?? 0, 2)
    }

    // Shape check only ("dddd-dd-dd"); keys of that shape order lexically as dates do.
    static func isDayKey(_ key: String) -> Bool {
        let chars = Array(key.utf8)
        guard chars.count == 10 else { return false }
        for (index, char) in chars.enumerated() {
            if index == 4 || index == 7 {
                guard char == UInt8(ascii: "-") else { return false }
            } else {
                guard char >= UInt8(ascii: "0"), char <= UInt8(ascii: "9") else { return false }
            }
        }
        return true
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    // MARK: - Splitting a measured interval (P9g)
    //
    // The tunnel measures how long it was up on a MONOTONIC clock and only then asks the wall clock
    // where that length belongs: an interval of `seconds` that ended at `end`. `split` cuts it at every
    // bucket boundary and every local midnight it crosses, so each share lies inside exactly one
    // bucket and one local day; `apportion` divides an amount measured over the same interval (bytes)
    // across those shares by their seconds. Both are exact — the shares' seconds sum to `seconds` and
    // the parts sum to the amount — so every bucket and every day gets its exact share and no total
    // moves. The wall clock only PLACES the interval; it never measures it.

    public struct Share: Equatable, Sendable {
        public var start: Date
        public var seconds: Int64

        public init(start: Date, seconds: Int64) {
            self.start = start
            self.seconds = seconds
        }
    }

    // `bucketWidth` is the document's. An interval spanning more than maxBuckets slots of it is cut at
    // a doubled width instead: that is what the document would coarsen to on adding it anyway, so the
    // result is the same. Days older than the ring's first are pruned at the next write, so their
    // midnights do not cut. Together that bounds the shares at maxBuckets + dayCount + 1, whatever the
    // interval. A non-positive `seconds`, one past 2⁴¹ (no measurement is that long, and its start
    // could not be computed safely), or an `end` outside bucketRange is ONE share at `end` — the caller
    // may still hold an amount measured over it, and it needs a place.
    public static func split(seconds: Int64, endingAt end: Date, bucketWidth: Int64, calendar: Calendar) -> [Share] {
        guard seconds > 0, seconds <= (1 << 41), let endSecond = AnalyticsDocument.bucketSeconds(end) else {
            return [Share(start: end, seconds: max(seconds, 0))]
        }
        let startSecond = endSecond - seconds
        var width = AnalyticsLedger.baseBucketWidth
        while width < bucketWidth, width < (1 << 42) { width *= 2 }
        while width < (1 << 42),
              (AnalyticsDocument.align(endSecond - 1, to: width) - AnalyticsDocument.align(startSecond, to: width)) / width + 1 > maxBuckets {
            width *= 2
        }
        let ringStart = calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: end))
            .map { Int64($0.timeIntervalSince1970.rounded(.up)) } ?? .min

        var shares: [Share] = []
        var cursor = startSecond
        var midnight = cursor < ringStart ? ringStart : nextMidnight(after: cursor, calendar: calendar)
        while cursor < endSecond {
            if midnight <= cursor { midnight = nextMidnight(after: cursor, calendar: calendar) }
            let next = min(endSecond, AnalyticsDocument.align(cursor, to: width) + width, midnight)
            shares.append(Share(start: Date(timeIntervalSince1970: TimeInterval(cursor)), seconds: next - cursor))
            cursor = next
        }
        return shares
    }

    // `amount` across `shares` in proportion to their seconds, each part the difference of two floors
    // of the running proportion, so the parts telescope to exactly `amount`. Full-width arithmetic: no
    // product can overflow, and with a negative share read as 0 the running total never passes the
    // whole, so no quotient can either. With no seconds to weigh by, the whole amount goes to the last
    // share — where the interval ended.
    public static func apportion(_ amount: Int64, over shares: [Share]) -> [Int64] {
        guard !shares.isEmpty else { return [] }
        let total = shares.reduce(Int64(0)) { $0 + max($1.seconds, 0) }
        guard total > 0 else {
            var parts = [Int64](repeating: 0, count: shares.count)
            parts[parts.count - 1] = amount
            return parts
        }
        var parts: [Int64] = []
        var elapsed: Int64 = 0
        var before: Int64 = 0
        for share in shares {
            elapsed += max(share.seconds, 0)
            let upTo = total.dividingFullWidth(amount.multipliedFullWidth(by: elapsed)).quotient
            parts.append(upTo - before)
            before = upTo
        }
        return parts
    }

    // MARK: - Cutting a measured interval for the chart's slots (P57)

    // The same interval cut for the rings (see "The chart's slots"): at every local midnight inside the
    // day ring, as `split` cuts; inside the last `hourSlots` local hours before `end`, at every hour;
    // inside the last hour's 5-minute slots, at every slot. Each share then lies in one local day, and
    // in one hour and one 5-minute slot wherever those rings could keep it — older hours and slots would
    // be pruned the moment this interval lands, so nothing is lost by not cutting them. Bounded at
    // dayCount + hourSlots + minuteSlots + 3 shares whatever the interval. Degenerate input — a
    // non-positive `seconds`, one past 2⁴¹, an `end` outside bucketRange — is ONE share at `end`, as
    // `split` answers it.
    public static func slotShares(seconds: Int64, endingAt end: Date, calendar: Calendar) -> [Share] {
        guard seconds > 0, seconds <= (1 << 41), let endSecond = AnalyticsDocument.bucketSeconds(end) else {
            return [Share(start: end, seconds: max(seconds, 0))]
        }
        let startSecond = endSecond - seconds
        let lastSecond = endSecond - 1
        let ringStart = calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: end))
            .map { Int64($0.timeIntervalSince1970.rounded(.up)) } ?? .min
        let hourFrom = hourStart(hourStart(lastSecond, calendar: calendar) - Int64(hourSlots - 1) * 3_600, calendar: calendar)
        let minuteFrom = minuteStart(lastSecond, calendar: calendar) - (minuteSlots - 1) * minuteWidth

        var shares: [Share] = []
        var cursor = startSecond
        while cursor < endSecond {
            var next = endSecond
            next = min(next, cursor < ringStart ? ringStart : nextMidnight(after: cursor, calendar: calendar))
            next = min(next, cursor < hourFrom ? hourFrom : nextHour(after: cursor, calendar: calendar))
            if cursor >= minuteFrom {
                next = min(next, minuteStart(cursor, calendar: calendar) + minuteWidth)
            } else {
                next = min(next, minuteFrom)
            }
            shares.append(Share(start: Date(timeIntervalSince1970: TimeInterval(cursor)), seconds: next - cursor))
            cursor = next
        }
        return shares
    }

    // The local hour holding `second`, as its first second since 1970 (a daylight-saving change skips or
    // repeats an hour; each one is still its own slot).
    public static func hourStart(_ second: Int64, calendar: Calendar) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(second))
        guard let start = calendar.dateInterval(of: .hour, for: date)?.start else {
            return AnalyticsDocument.align(second, to: 3_600)
        }
        return Int64(start.timeIntervalSince1970.rounded(.down))
    }

    // The 5-minute slot holding `second`, counted from the start of its local hour, so a slot never
    // crosses an hour (and so never a midnight) in any time zone.
    public static func minuteStart(_ second: Int64, calendar: Calendar) -> Int64 {
        let hour = hourStart(second, calendar: calendar)
        return hour + (second - hour) / minuteWidth * minuteWidth
    }

    // Strictly after `second`: the start of the next local hour.
    private static func nextHour(after second: Int64, calendar: Calendar) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(second))
        let end = calendar.dateInterval(of: .hour, for: date).map { Int64($0.end.timeIntervalSince1970.rounded(.up)) }
        return max(end ?? AnalyticsDocument.align(second, to: 3_600) + 3_600, second + 1)
    }

    // Strictly after `second`, so the walk in `split` always advances. Whole seconds: every time zone
    // in use today is offset by whole seconds, so a midnight is never between two of them.
    private static func nextMidnight(after second: Int64, calendar: Calendar) -> Int64 {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(second)))
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return .max }
        return max(Int64(next.timeIntervalSince1970.rounded(.up)), second + 1)
    }
}

// MARK: - AnalyticsDocument

public nonisolated struct AnalyticsDocument: Sendable, Equatable {

    // 2 = the analytics store v2. v1 had no field to carry a number (connection-stats.json).
    public static let currentSchema = 2

    public var schema: Int
    // Made once per document; a future sync merges by it. A reset starts a new document.
    public var id: UUID
    // +1 per write.
    public var revision: Int64
    // When counting began, in seconds since 1970. The ONE date that is not a bucket boundary.
    public var since: TimeInterval
    public var counters: [String: Int64]
    // Seconds; always baseBucketWidth × 2ⁿ.
    public var bucketWidth: Int64
    // Bucket start (seconds since 1970, a multiple of bucketWidth) → that bucket's sums.
    public var buckets: [Int64: [String: Int64]]
    // Local "yyyy-MM-dd" → that day's sums. The last `dayCount` days.
    public var days: [String: [String: Int64]]
    // P57 (AnalyticsLedger § The chart's slots). 5-minute slot start → sums: the hour ending with the
    // latest active slot.
    public var minutes: [Int64: [String: Int64]]
    // Local hour start → sums: the latest `hourSlots` active hours.
    public var hours: [Int64: [String: Int64]]

    public init(since: TimeInterval, id: UUID = UUID()) {
        self.schema = Self.currentSchema
        self.id = id
        self.revision = 0
        self.since = since
        self.counters = [:]
        self.bucketWidth = AnalyticsLedger.baseBucketWidth
        self.buckets = [:]
        self.days = [:]
        self.minutes = [:]
        self.hours = [:]
    }

    public var isWritable: Bool { schema <= Self.currentSchema }

    // MARK: Adding

    // Adds `value` to `counter`, and — when named — to the `bucket` key of the time bucket holding
    // `date`, of its 5-minute slot, its local hour and its local day (P57: the chart's three units),
    // and to the `day` key of `date`'s local day. Every one of them is always ALSO in the counter
    // total, which is what makes "total minus the bars" a baseline and never negative. An add of 0
    // still creates the bucket and day keys: that is how a writer says "measured, and it was nothing"
    // (the slot rings keep only slots where something happened).
    public mutating func add(
        _ value: Int64,
        to counter: String,
        bucket bucketKey: String? = nil,
        day dayKey: String? = nil,
        at date: Date,
        calendar: Calendar
    ) {
        counters[counter] = Self.saturatingSum(counters[counter] ?? 0, value)
        if let bucketKey {
            if let seconds = Self.bucketSeconds(date) {
                addToBucket(value, key: bucketKey, second: seconds)
                addToSlots(value, key: bucketKey, second: seconds, calendar: calendar)
            }
            addToDay(value, key: bucketKey, at: date, calendar: calendar)
        }
        if let dayKey, dayKey != bucketKey {
            addToDay(value, key: dayKey, at: date, calendar: calendar)
        }
        boundSlots()
    }

    // P9g, the tunnel's interval: `seconds` of protection measured on a monotonic clock and ending at
    // `end`, plus — when they were measured — the bytes moved over the same interval. The counters rise
    // by exactly `seconds` and `trafficBytes`. The buckets get their exact shares as AnalyticsLedger.split
    // places them at this document's width; the days, hours and 5-minute slots theirs as
    // AnalyticsLedger.slotShares places them (P57), the bytes apportioned by seconds over those same
    // shares, so the three rings agree to the byte. nil adds no traffic key at all — unmeasured is not
    // zero.
    public mutating func addProtectedInterval(seconds: Int64, trafficBytes: Int64?, endingAt end: Date, calendar: Calendar) {
        typealias Key = AnalyticsLedger.Key
        let shares = AnalyticsLedger.split(seconds: seconds, endingAt: end, bucketWidth: bucketWidth, calendar: calendar)
        let slotShares = AnalyticsLedger.slotShares(seconds: seconds, endingAt: end, calendar: calendar)
        for share in shares {
            counters[Key.protectedSeconds] = Self.saturatingSum(counters[Key.protectedSeconds] ?? 0, share.seconds)
            if let second = Self.bucketSeconds(share.start) {
                addToBucket(share.seconds, key: Key.protectedSeconds, second: second)
            }
        }
        for share in slotShares {
            addToRings(share.seconds, key: Key.protectedSeconds, at: share.start, calendar: calendar)
        }
        if let trafficBytes {
            counters[Key.trafficBytes] = Self.saturatingSum(counters[Key.trafficBytes] ?? 0, trafficBytes)
            for (share, part) in zip(shares, AnalyticsLedger.apportion(trafficBytes, over: shares)) {
                if let second = Self.bucketSeconds(share.start) {
                    addToBucket(part, key: Key.trafficBytes, second: second)
                }
            }
            for (share, part) in zip(slotShares, AnalyticsLedger.apportion(trafficBytes, over: slotShares)) {
                addToRings(part, key: Key.trafficBytes, at: share.start, calendar: calendar)
            }
        }
        boundSlots()
    }

    private mutating func addToBucket(_ value: Int64, key: String, second: Int64) {
        let start = Self.align(second, to: bucketWidth)
        var sums = buckets[start] ?? [:]
        sums[key] = Self.saturatingSum(sums[key] ?? 0, value)
        buckets[start] = sums
        coarsen()
    }

    private mutating func addToDay(_ value: Int64, key: String, at date: Date, calendar: Calendar) {
        let day = AnalyticsLedger.dayKey(for: date, calendar: calendar)
        var sums = days[day] ?? [:]
        sums[key] = Self.saturatingSum(sums[key] ?? 0, value)
        days[day] = sums
    }

    private mutating func addToSlots(_ value: Int64, key: String, second: Int64, calendar: Calendar) {
        Self.add(value, key: key, to: &minutes, at: AnalyticsLedger.minuteStart(second, calendar: calendar))
        Self.add(value, key: key, to: &hours, at: AnalyticsLedger.hourStart(second, calendar: calendar))
    }

    // The day, and the hour and the 5-minute slot when the instant is one a bucket may hold.
    private mutating func addToRings(_ value: Int64, key: String, at date: Date, calendar: Calendar) {
        if let second = Self.bucketSeconds(date) {
            addToSlots(value, key: key, second: second, calendar: calendar)
        }
        addToDay(value, key: key, at: date, calendar: calendar)
    }

    private static func add(_ value: Int64, key: String, to slots: inout [Int64: [String: Int64]], at start: Int64) {
        var sums = slots[start] ?? [:]
        sums[key] = saturatingSum(sums[key] ?? 0, value)
        slots[start] = sums
    }

    // MARK: Merging

    // Pure and exact: counters and days summed; buckets brought to the wider of the two widths (both
    // are baseBucketWidth × 2ⁿ on the same 1970 grid, so every narrow bucket lies inside exactly one
    // wide one) and summed, then coarsened again if the union spans more than maxBuckets; `since` the
    // earliest. Identity (`id`, `revision`) is self's. `schema` is the newer of the two, so a merge
    // that took in a newer document is not writable either. P57: the 5-minute slots and the hours are
    // summed slot by slot and bounded again — exact too, because each document kept its own latest
    // slots, so every slot the union keeps was kept whole by both.
    public func merging(_ other: AnalyticsDocument) -> AnalyticsDocument {
        var result = self
        result.schema = max(schema, other.schema)
        result.since = min(since, other.since)
        Self.sum(&result.counters, other.counters)
        var theirs = other
        let width = max(result.bucketWidth, theirs.bucketWidth)
        result.rebucket(to: width)
        theirs.rebucket(to: width)
        for (start, sums) in theirs.buckets {
            var merged = result.buckets[start] ?? [:]
            Self.sum(&merged, sums)
            result.buckets[start] = merged
        }
        result.coarsen()
        for (key, sums) in other.days {
            var merged = result.days[key] ?? [:]
            Self.sum(&merged, sums)
            result.days[key] = merged
        }
        for (start, sums) in other.minutes {
            var merged = result.minutes[start] ?? [:]
            Self.sum(&merged, sums)
            result.minutes[start] = merged
        }
        for (start, sums) in other.hours {
            var merged = result.hours[start] ?? [:]
            Self.sum(&merged, sums)
            result.hours[start] = merged
        }
        result.boundSlots()
        return result
    }

    // MARK: Bounds

    // The number of bucket slots between the earliest and the latest start, inclusive — what a dense
    // chart would draw. Never more than maxBuckets after any mutation.
    public var bucketSpan: Int64 {
        guard let low = buckets.keys.min(), let high = buckets.keys.max() else { return 0 }
        return (high - low) / bucketWidth + 1
    }

    // Brings any decoded document inside the invariants: a width of baseBucketWidth × 2ⁿ, every start
    // aligned to it, the span within maxBuckets. Only re-buckets; every sum survives.
    mutating func normalize() {
        // Capped at 2⁴²: wide enough for any span inside bucketRange, and a hand-edited width near
        // Int64.max cannot make the doubling overflow.
        var width = AnalyticsLedger.baseBucketWidth
        while width < bucketWidth, width < (1 << 42) { width *= 2 }
        rebucket(to: width)
        coarsen()
    }

    // Doubles the width, merging pairs, as often as the span needs. Terminates: starts are confined to
    // AnalyticsLedger.bucketRange, so the width never has to pass 2⁴¹ / maxBuckets.
    mutating func coarsen() {
        while bucketSpan > AnalyticsLedger.maxBuckets {
            rebucket(to: bucketWidth * 2)
        }
    }

    mutating func rebucket(to width: Int64) {
        var rebucketed: [Int64: [String: Int64]] = [:]
        for (start, sums) in buckets {
            let aligned = Self.align(start, to: width)
            var merged = rebucketed[aligned] ?? [:]
            Self.sum(&merged, sums)
            rebucketed[aligned] = merged
        }
        buckets = rebucketed
        bucketWidth = width
    }

    // Run by both writers before every write (AnalyticsLedger.write, AppGroup.replaceTunnelDocument):
    // the day ring keeps its last `dayCount` days, and the slot rings nothing older than its first day.
    mutating func pruneDays(now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(AnalyticsLedger.dayCount - 1), to: today) else {
            return
        }
        let cutoff = AnalyticsLedger.dayKey(for: first, calendar: calendar)
        days = days.filter { AnalyticsLedger.isDayKey($0.key) && $0.key >= cutoff }
        let firstSecond = Int64(first.timeIntervalSince1970.rounded(.up))
        minutes = minutes.filter { $0.key >= firstSecond }
        hours = hours.filter { $0.key >= firstSecond }
    }

    // The slot rings' bounds (AnalyticsLedger § The chart's slots): a slot in which nothing happened is
    // not kept; the 5-minute slots only within the hour ending with the latest one; the latest
    // `hourSlots` hours. After every add and merge, so no document ever holds more.
    mutating func boundSlots() {
        minutes = minutes.filter { Self.isActive($0.value) }
        if let latest = minutes.keys.max() {
            let first = latest - (AnalyticsLedger.minuteSlots - 1) * AnalyticsLedger.minuteWidth
            minutes = minutes.filter { $0.key >= first }
        }
        hours = hours.filter { Self.isActive($0.value) }
        if hours.count > AnalyticsLedger.hourSlots {
            let kept = Set(hours.keys.sorted().suffix(AnalyticsLedger.hourSlots))
            hours = hours.filter { kept.contains($0.key) }
        }
    }

    static func isActive(_ sums: [String: Int64]) -> Bool {
        sums.values.contains { $0 != 0 }
    }

    // MARK: Migration (P57)

    // A document written before P57 has buckets and a day ring but no slot rings. What the buckets
    // determine exactly is carried into them, once, when such a document is decoded (the encoded
    // `hours` key is what says it has been):
    //   • a bucket inside one local hour → that hour, and inside one 5-minute slot → that slot (so
    //     buckets up to 20 minutes wide; the rings' bounds then keep what they keep);
    //   • a bucket inside one local day → its traffic and red keys to that day (the day ring always had
    //     the protected seconds, exactly);
    //   • a bucket across midnights: its protected seconds on each of its days are known exactly from
    //     the day ring (each day's protected seconds less those of the buckets wholly inside it, taken
    //     in time order), and its traffic is divided by those seconds — the ledger's own rule inside an
    //     interval (AnalyticsLedger.apportion), applied to the whole bucket, so the split between its
    //     days is an estimate; its red count lies on no known side and stays in the baseline.
    // What no bucket places stays in the counters, as the baseline every cumulative line starts from:
    // nothing is lost, only bars at a finer unit than the buckets kept. A day key already present (a
    // newer build wrote it, an older one dropped the rings) is never added to.
    mutating func migrateLegacyBuckets(calendar: Calendar) {
        typealias Key = AnalyticsLedger.Key
        let dayKeys = [Key.trafficBytes, Key.killSwitchBlocks, Key.failures]
        let present = Set(days.flatMap { day, sums in sums.keys.map { day + " " + $0 } })
        func addToDay(_ value: Int64, _ key: String, _ day: String) {
            guard !present.contains(day + " " + key), days[day] != nil || value != 0 else { return }
            var sums = days[day] ?? [:]
            sums[key] = Self.saturatingSum(sums[key] ?? 0, value)
            days[day] = sums
        }
        var remaining = days.mapValues { $0[Key.protectedSeconds] ?? 0 }
        var crossing: [(sums: [String: Int64], days: [String])] = []
        for start in buckets.keys.sorted() {
            guard let sums = buckets[start] else { continue }
            let last = start + bucketWidth - 1
            if AnalyticsLedger.hourStart(start, calendar: calendar) == AnalyticsLedger.hourStart(last, calendar: calendar) {
                Self.sum(&hours[AnalyticsLedger.hourStart(start, calendar: calendar), default: [:]], sums)
                if AnalyticsLedger.minuteStart(start, calendar: calendar) == AnalyticsLedger.minuteStart(last, calendar: calendar) {
                    Self.sum(&minutes[AnalyticsLedger.minuteStart(start, calendar: calendar), default: [:]], sums)
                }
            }
            let firstDay = AnalyticsLedger.dayKey(for: Date(timeIntervalSince1970: TimeInterval(start)), calendar: calendar)
            let lastDay = AnalyticsLedger.dayKey(for: Date(timeIntervalSince1970: TimeInterval(last)), calendar: calendar)
            if firstDay == lastDay {
                for key in dayKeys { if let value = sums[key] { addToDay(value, key, firstDay) } }
                remaining[firstDay, default: 0] -= sums[Key.protectedSeconds] ?? 0
            } else {
                // Only the days the ring holds: a day it does not hold had no protected time to weigh by.
                crossing.append((sums, days.keys.filter { $0 >= firstDay && $0 <= lastDay }.sorted()))
            }
        }
        for (sums, overlapped) in crossing {
            var left = max(0, sums[Key.protectedSeconds] ?? 0)
            var weights: [AnalyticsLedger.Share] = []
            for day in overlapped {
                let take = min(max(0, remaining[day] ?? 0), left)
                remaining[day, default: 0] -= take
                left -= take
                weights.append(AnalyticsLedger.Share(start: .distantPast, seconds: take))
            }
            guard let traffic = sums[Key.trafficBytes], weights.contains(where: { $0.seconds > 0 }) else { continue }
            for (day, part) in zip(overlapped, AnalyticsLedger.apportion(traffic, over: weights)) where part != 0 {
                addToDay(part, Key.trafficBytes, day)
            }
        }
        boundSlots()
    }

    // MARK: Arithmetic

    // Floor alignment, correct for negative seconds too.
    static func align(_ seconds: Int64, to width: Int64) -> Int64 {
        let quotient = seconds / width
        let floored = (seconds % width != 0 && seconds < 0) ? quotient - 1 : quotient
        return floored * width
    }

    static func bucketSeconds(_ date: Date) -> Int64? {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        guard seconds.isFinite,
              seconds >= Double(AnalyticsLedger.bucketRange.lowerBound),
              seconds <= Double(AnalyticsLedger.bucketRange.upperBound) else { return nil }
        return Int64(seconds)
    }

    // A total that reached Int64.max stops there rather than trapping inside a Network Extension.
    public static func saturatingSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs > 0 ? .max : .min
    }

    static func sum(_ into: inout [String: Int64], _ other: [String: Int64]) {
        for (key, value) in other {
            into[key] = saturatingSum(into[key] ?? 0, value)
        }
    }
}

// MARK: - Codable (hand-written, lenient)

extension AnalyticsDocument: Codable {

    private enum CodingKeys: String, CodingKey {
        case schema, id, revision, since, counters, bucketWidth, buckets, days, minutes, hours
    }

    // JSON object keys are strings. A key that is not a start in range is dropped: its sums are still
    // inside the counter totals, so the only loss is the bar, never a count.
    private static func slots(_ raw: [String: [String: Int64]]) -> [Int64: [String: Int64]] {
        var decoded: [Int64: [String: Int64]] = [:]
        for (key, sums) in raw {
            guard let start = Int64(key), AnalyticsLedger.bucketRange.contains(start) else { continue }
            var merged = decoded[start] ?? [:]
            sum(&merged, sums)
            decoded[start] = merged
        }
        return decoded
    }

    private static func encoded(_ slots: [Int64: [String: Int64]]) -> [String: [String: Int64]] {
        Dictionary(uniqueKeysWithValues: slots.map { (String($0.key), $0.value) })
    }

    // Every field is decodeIfPresent with a default — an ABSENT key never fails the document. A
    // PRESENT key of the wrong type does, on purpose: the caller then has `.unreadable`, which is
    // moved aside, instead of a default that would be written over the user's numbers.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        counters = try container.decodeIfPresent([String: Int64].self, forKey: .counters) ?? [:]
        bucketWidth = try container.decodeIfPresent(Int64.self, forKey: .bucketWidth)
            ?? AnalyticsLedger.baseBucketWidth
        let decoded = Self.slots(try container.decodeIfPresent([String: [String: Int64]].self, forKey: .buckets) ?? [:])
        buckets = decoded
        days = try container.decodeIfPresent([String: [String: Int64]].self, forKey: .days) ?? [:]
        minutes = Self.slots(try container.decodeIfPresent([String: [String: Int64]].self, forKey: .minutes) ?? [:])
        hours = Self.slots(try container.decodeIfPresent([String: [String: Int64]].self, forKey: .hours) ?? [:])
        // A document without `since` has still been counting since at least its earliest bucket; with
        // no bucket either, the moment it is read is the only honest anchor.
        since = try container.decodeIfPresent(Double.self, forKey: .since)
            ?? decoded.keys.min().map(Double.init)
            ?? Date().timeIntervalSince1970
        normalize()
        // P57: every document written since carries `hours`, even empty; one without it predates the
        // rings, and what its buckets determine is carried into them (migrateLegacyBuckets).
        if !container.contains(.hours) {
            let calendar = decoder.userInfo[AnalyticsLedger.calendarInfoKey] as? Calendar ?? AnalyticsLedger.calendar()
            migrateLegacyBuckets(calendar: calendar)
        }
        boundSlots()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(id, forKey: .id)
        try container.encode(revision, forKey: .revision)
        try container.encode(since, forKey: .since)
        try container.encode(counters, forKey: .counters)
        try container.encode(bucketWidth, forKey: .bucketWidth)
        // String keys explicitly: JSONEncoder encodes an [Int64: …] dictionary as a flat ARRAY of
        // alternating keys and values, which is neither readable nor the shape the format promises.
        try container.encode(Self.encoded(buckets), forKey: .buckets)
        try container.encode(days, forKey: .days)
        try container.encode(Self.encoded(minutes), forKey: .minutes)
        try container.encode(Self.encoded(hours), forKey: .hours)
    }
}
