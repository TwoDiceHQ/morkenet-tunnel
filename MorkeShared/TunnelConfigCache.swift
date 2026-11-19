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

#if os(macOS)
import Foundation
// SHA-256 for the record's digest. CommonCrypto is part of libSystem, which every process links, so
// the macOS extension gains no framework and no dependency (MorkeShared stays inside the NE budget).
import CommonCrypto

// MARK: - TunnelConfigCache (T-MAC-26, macOS only; rebuilt by T-MAC-26h)
//
// WHERE THE MAC'S TUNNEL CREDENTIAL LIVES. The sing-box config — the per-account VLESS uuid and the
// REALITY parameters — reaches the system extension only through the app's XPC channel (TunnelControl: a
// `put` on the extension's Mach service, whose listener accepts only our signed app). The extension keeps it
// here, so that EVERY start has something to run — an in-app Connect, on-demand, the Kill Switch's always-on
// rule, System Settings, the menu-bar VPN item, a reboot: one file at the root of the extension's App-Group
// container. The extension runs as root, so that container is root's, /var/root/Library/Group Containers/
// <appGroupID>/, under a /var/root that is root:wheel 0750 (P76, measured). The file is created 0600. No
// other account, and no process of the console user, can read it; the NE store the config used to sit in is
// root:wheel 0644 (T-MAC-20). This is the shape Apple's DTS gives a system extension for a secret ("do all
// your keychain operations in the sysex … have it pass that request to the sysex via IPC"), and the one SFM,
// Proton and Tailscale ship (P84, Docs/reference/mac-vpn-architecture-2026-11-16/).
//
// WHAT A START RUNS (T-MAC-26h, P84 point 4): the record, when it is intact, from ANY start, and nothing
// else. The profile carries no account state, so a start reads nothing from its view of the profile, not even
// `includeAllNetworks` (the Kill Switch is the record's, below), and a lagging view (P78e/f/g, 2026-11-16) decides
// nothing. Start options are
// never read: any process may pass them
// (SCNetworkConnectionStart's userOptions). T-MAC-26f's two proofs, the start token and the account's
// generation in the profile, and its `viewAgrees`, went with the provider-message handover that needed them.
//
// A CACHE, NEVER THE ONLY COPY (the T-CFG-41 rule): missing, unreadable, an unknown format, a wrong length or
// digest — every one refuses the start, and the next in-app Connect, which re-fetches and puts a fresh config,
// repairs it. Nothing here re-fetches.
//
// ONE RECORD PER MAC. A put replaces it, whichever macOS user's app sent it (the profile is one per Mac too:
// P78i measured both macOS users sharing one configuration), so a later start runs the last Connect's account,
// as every start did before. The record names the macOS user whose app put it and the hash of the account it
// is for, so the app can tell its own record from another user's or another account's (`state`), and so a
// sign-out takes only its own user's record (`revoke`).
//
// DE-AUTHORISING IS A REVOKE. Sign-out, Reset VPN profile, account deletion and a lapse ask the extension to
// discard the record. It goes when the caller's macOS user put it (whatever account it names: that user is
// taking their credential off the Mac), or when nothing can read it; another macOS user's record is kept, so a
// late revoke never takes a Connect someone else made since. A start never deletes a record but a corrupt one.
//
// THE KILL SWITCH IS THE APP'S WORD, KEPT IN THE RECORD (the maintainer, 2026-11-17, «Как на iOS, с XPC»). The
// stack follows the Kill Switch as on iOS: gVisor with it on, the config's own stack (the server pins `system`)
// with it off (T-CFG-17: `system` and `mixed` black-hole all traffic under an enforced includeAllNetworks). On the
// Mac the extension takes the Kill Switch from the flag the app sent over XPC — with every put, and again on every
// Kill Switch change (`acceptKillSwitch`, TunnelControl's `setKillSwitch`) — never from its view of the profile's
// includeAllNetworks, which can lag the app's save (P78e/f/g; T-MAC-26h's review finding 3: the Kill Switch
// switched on in Settings, on-demand armed, and a first start that saw neither). The app sends ON, and waits for
// the answer, BEFORE it saves includeAllNetworks on, and OFF only AFTER it saved it off (VPNCore), so the flag is
// on whenever the profile may enforce includeAllNetworks; a flag left on with the Kill Switch off only costs the
// gVisor stack. The flag belongs to the Mac's one profile, not to an account, so any macOS user's app sets it.
// `startConfig` hands the start the config with the stack the flag asks for; the record keeps the bytes as put.
//
// THE RECORD, format version 4 — all binary, so nothing is parsed before the version is known:
//   bytes 0…3     magic "MKTC"
//   byte  4       format version (4)
//   byte  5       flags: 1 when the app last said the Kill Switch is on, else 0
//   bytes 6…9     the uid of the macOS user whose app put it, UInt32 big-endian (the XPC peer's)
//   bytes 10…41   the account's hash, 32 bytes (TunnelControl.accountHash; never the account id)
//   bytes 42…45   the config's length in bytes, UInt32 big-endian
//   bytes 46…77   SHA-256 of the config bytes
//   bytes 78…     the config bytes exactly as put (never empty; exactly `length` of them)
// A record that is not this shape — another version (T-MAC-26's 1, T-MAC-26b's 2, T-MAC-26f's 3 with its
// generation and token), a length that is not the rest of the file, a digest that does not match — is never
// guessed at: a start discards it, so a corrupt body can never reach the engine and fail every start in a loop.
//
// WRITES ARE ATOMIC AND DURABLE: the bytes go to a staging file created 0600 with O_EXCL beside the cache, are
// flushed with F_FULLFSYNC, renamed over it, and the directory is flushed so the rename survives a power loss;
// a reader sees the old file or the new one and never a part. In the extension every call that touches the
// file runs on TunnelControl.queue, so a put, a revoke and a start's read never interleave. Foundation, POSIX
// and CommonCrypto only, no state, nothing logged: the extension logs each outcome as a constant, never a value
// or a path.
public nonisolated enum TunnelConfigCache {

    public static let formatVersion: UInt8 = 4
    static let magic = Data("MKTC".utf8)
    static let digestLength = Int(CC_SHA256_DIGEST_LENGTH)
    // The account's hash is a SHA-256 (TunnelControl.accountHash).
    public static let accountLength = digestLength
    static let headerLength = 4 + 1 + 1 + 4 + accountLength + 4 + digestLength
    static let stagingName = AppGroup.tunnelConfigCacheName + ".staging"
    // Files earlier builds kept beside the record: T-MAC-26d's second slot (a whole older record) and
    // T-MAC-26f's spent start token. Neither is read any more; a write or a discard removes them where it finds
    // them, so a Mac that ran those builds keeps no second record in root's container.
    static let retiredNames = [
        AppGroup.tunnelConfigCacheName + ".previous",
        AppGroup.tunnelConfigCacheName + ".used-token",
    ]

    // What the file holds when it is a well-formed version-4 record.
    public struct Record: Sendable, Equatable {
        public let config: Data
        public let killSwitch: Bool
        public let account: Data
        public let putter: uid_t
    }

    // Why a start found nothing to run. The raw value is the log line's wording: a constant, no value.
    public enum Refusal: String, Sendable, Equatable {
        case noContainer       = "no App Group container"
        case absent            = "no cached config"
        case unreadable        = "cached config unreadable"
        case unsupportedFormat = "cached config in an unknown format or corrupt"
        case notRunnable       = "cached config is not a JSON object, the TUN stack cannot be set"
    }

    // What became of a record a refusal found unusable for good (an unknown or corrupt one): removed, or
    // left because the removal failed (with the POSIX errno when known).
    public enum Discard: Sendable, Equatable {
        case notNeeded
        case removed
        case failed(errno: Int32?)
    }

    public enum ReadOutcome: Sendable, Equatable {
        case config(Data)
        case refused(Refusal, Discard)
    }

    public enum WriteFailure: Error, Sendable, Equatable {
        case noContainer
        case emptyConfig
        case malformedAccount
        // The POSIX errno of the step that failed (create, write, sync or rename).
        case posix(errno: Int32)
    }

    public static func url(in container: URL) -> URL {
        container.appendingPathComponent(AppGroup.tunnelConfigCacheName)
    }

    // MARK: The start's decision (the extension's startTunnel, macOS)

    public struct StartDecision: Sendable, Equatable {
        public let outcome: ReadOutcome
        // The start came with options. They are never read, only logged as ignored, as a constant.
        public let optionsIgnored: Bool
        // Whether the record that runs says the Kill Switch is on, so its config runs on gVisor (false when
        // refused). For the start's constant log line only: the stack is already in `outcome`'s config.
        public let killSwitch: Bool
    }

    // What a start runs: the record, when it is intact, and nothing else, whatever start it is, on the stack the
    // record's Kill Switch asks for — every `tun` inbound on gVisor with it on, the bytes as put with it off (the
    // header's THE KILL SWITCH IS THE APP'S WORD). `options` are never read (the header). Only a record that can
    // never run for anyone — an unknown or corrupt one, or one the stack rewrite cannot read, which a put never
    // caches — is discarded; an unreadable one is left for the next start, since a read error says nothing about
    // the bytes.
    public static func startConfig(options: [String: Any]?, container: URL? = nil) -> StartDecision {
        let ignored = !(options ?? [:]).isEmpty
        guard let container = container ?? AppGroup.defaultContainer() else {
            return StartDecision(outcome: .refused(.noContainer, .notNeeded), optionsIgnored: ignored, killSwitch: false)
        }
        switch load(url(in: container)) {
        case .absent:
            return StartDecision(outcome: .refused(.absent, .notNeeded), optionsIgnored: ignored, killSwitch: false)
        case .unreadable:
            return StartDecision(outcome: .refused(.unreadable, .notNeeded), optionsIgnored: ignored, killSwitch: false)
        case .corrupt:
            return StartDecision(outcome: .refused(.unsupportedFormat, discard(container: container)),
                                 optionsIgnored: ignored, killSwitch: false)
        case .record(let record):
            guard let runnable = try? SingBoxGVisorStack.forStart(SingBoxConfig(raw: record.config),
                                                                  includeAllNetworks: record.killSwitch) else {
                return StartDecision(outcome: .refused(.notRunnable, discard(container: container)),
                                     optionsIgnored: ignored, killSwitch: false)
            }
            return StartDecision(outcome: .config(runnable.raw), optionsIgnored: ignored,
                                 killSwitch: record.killSwitch)
        }
    }

    // MARK: The put (TunnelControl's `put`)

    public enum PutRefusal: String, Sendable, Equatable {
        case malformed     = "put malformed (an empty config, or an account that is not a hash)"
        case invalidConfig = "put config is not a JSON object"
        case writeFailed   = "config cache write failed"
    }

    public enum PutOutcome: Sendable, Equatable {
        case cached
        case refused(PutRefusal, errno: Int32?)
    }

    // The extension's half of a put. The config is checked to be a JSON object the TUN-stack rewrite can work
    // on BEFORE anything is written, so an invalid config is never cached, and only then is the record written,
    // replacing the one in place, with the Kill Switch the Connect saved. `putter` is the uid of the XPC peer that
    // sent it, never a value it chose.
    public static func acceptPut(
        config: Data,
        killSwitch: Bool,
        account: Data,
        putter: uid_t,
        container: URL? = nil
    ) -> PutOutcome {
        guard !config.isEmpty, account.count == accountLength else { return .refused(.malformed, errno: nil) }
        do {
            _ = try SingBoxGVisorStack.applying(to: SingBoxConfig(raw: config))
        } catch {
            return .refused(.invalidConfig, errno: nil)
        }
        do {
            try write(config, killSwitch: killSwitch, account: account, putter: putter, container: container)
        } catch WriteFailure.posix(let code) {
            return .refused(.writeFailed, errno: code)
        } catch {
            return .refused(.writeFailed, errno: nil)
        }
        return .cached
    }

    // MARK: The revoke (TunnelControl's `revoke`)

    public enum RevokeOutcome: Sendable, Equatable {
        case removed               // the caller's macOS user's record, or one nothing can read, is gone
        case nothingToRemove       // no record at all
        case keptAnotherUsers      // the record is another macOS user's: kept
        case failed(errno: Int32?) // a record that had to go could not be removed
    }

    // The header's DE-AUTHORISING IS A REVOKE. `caller` is the uid of the XPC peer asking.
    public static func acceptRevoke(caller: uid_t, container: URL? = nil) -> RevokeOutcome {
        guard let container = container ?? AppGroup.defaultContainer() else { return .nothingToRemove }
        switch load(url(in: container)) {
        case .absent:
            return .nothingToRemove
        case .record(let record) where record.putter != caller:
            return .keptAnotherUsers
        case .record, .unreadable, .corrupt:
            // The caller's own, or one nothing can read: an unreadable record may be the caller's, and the app
            // is taking its credential away.
            switch discard(container: container) {
            case .removed, .notNeeded: return .removed
            case .failed(let code):    return .failed(errno: code)
            }
        }
    }

    // MARK: The Kill Switch (TunnelControl's `setKillSwitch`)

    public enum KillSwitchOutcome: Sendable, Equatable {
        case set                    // the record now says what the app said (it may have already)
        case nothingHeld            // no record a start would run: nothing to set, and nothing can start
        case failed(errno: Int32?)  // a record is there and does not say it: the write, or an unreadable one's
                                    // removal, failed
    }

    // The header's THE KILL SWITCH IS THE APP'S WORD: the record's flag becomes what the app said, whichever macOS
    // user put it (the flag follows the Mac's one profile). Only the flag changes; the config, the account and the putter stay,
    // through the same atomic write. An unreadable record is removed, as a revoke removes it: it may run later on a
    // flag that does not say this, and keeping it would fail every Kill Switch change; `failed` when it cannot be
    // removed, so the app saves no includeAllNetworks over a flag it could not set.
    public static func acceptKillSwitch(_ on: Bool, container: URL? = nil) -> KillSwitchOutcome {
        guard let container = container ?? AppGroup.defaultContainer() else { return .nothingHeld }
        switch load(url(in: container)) {
        case .absent, .corrupt:
            // A corrupt record never runs: the next start discards it.
            return .nothingHeld
        case .unreadable:
            // It may run later, on a flag that does not say this, so it goes, as a revoke takes it: the next start
            // refuses, and the Connect's put writes a fresh record (T-MAC-26h's second review, finding 2: kept, it
            // failed every Kill Switch Connect, before the put that would have replaced it).
            switch discard(container: container) {
            case .removed, .notNeeded: return .nothingHeld
            case .failed(let code):    return .failed(errno: code)
            }
        case .record(let record) where record.killSwitch == on:
            return .set
        case .record(let record):
            do {
                try write(record.config, killSwitch: on, account: record.account, putter: record.putter,
                          container: container)
            } catch WriteFailure.posix(let code) {
                return .failed(errno: code)
            } catch {
                return .failed(errno: nil)
            }
            return .set
        }
    }

    // MARK: The state (TunnelControl's `state`)

    // What the app may know about the record: whether a start would run one, whether the caller's macOS user put
    // it, and — only then — the hash of its account (another user's account is none of the caller's business).
    // Never a config byte, a length or a digest.
    public static func state(caller: uid_t, container: URL? = nil) -> TunnelControl.State {
        guard let container = container ?? AppGroup.defaultContainer(),
              case .record(let record) = load(url(in: container)) else {
            return TunnelControl.State(held: false, account: nil, putByCaller: false)
        }
        let mine = record.putter == caller
        return TunnelControl.State(held: true, account: mine ? record.account : nil, putByCaller: mine)
    }

    // MARK: Write

    // Makes `config` the record, with the Kill Switch flag, the `account` hash and the `putter` uid.
    // Throws, never partially writes: on any failure the previous record (if any) is still the file in place.
    public static func write(
        _ config: Data,
        killSwitch: Bool = false,
        account: Data,
        putter: uid_t,
        container: URL? = nil
    ) throws {
        guard !config.isEmpty else { throw WriteFailure.emptyConfig }
        guard account.count == accountLength else { throw WriteFailure.malformedAccount }
        guard let container = container ?? AppGroup.defaultContainer() else { throw WriteFailure.noContainer }
        do {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        } catch {
            throw WriteFailure.posix(errno: posixCode(of: error) ?? EIO)
        }
        let staging = container.appendingPathComponent(stagingName)
        let target = url(in: container)
        let bytes = encode(config, killSwitch: killSwitch, account: account, putter: putter)

        // A staging file left by a process killed mid-write goes first; O_EXCL then refuses anything
        // that appeared since, and O_NOFOLLOW a link put in its place.
        _ = staging.withUnsafeFileSystemRepresentation { unlink($0!) }
        let fd: Int32 = staging.withUnsafeFileSystemRepresentation {
            open($0!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw WriteFailure.posix(errno: errno) }

        var failure: Int32 = 0
        // Explicit, so no umask or inherited ACL default can leave it wider than owner-only.
        if fchmod(fd, mode_t(0o600)) != 0 { failure = errno }
        if failure == 0 {
            failure = bytes.withUnsafeBytes { buffer -> Int32 in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    offset += written
                }
                return 0
            }
        }
        if failure == 0 { failure = fullSync(fd) }
        if close(fd) != 0, failure == 0 { failure = errno }
        if failure == 0 {
            let renamed: Int32 = staging.withUnsafeFileSystemRepresentation { from in
                target.withUnsafeFileSystemRepresentation { to in rename(from!, to!) == 0 ? 0 : errno }
            }
            failure = renamed
        }
        if failure != 0 {
            _ = staging.withUnsafeFileSystemRepresentation { unlink($0!) }
            throw WriteFailure.posix(errno: failure)
        }
        // What earlier builds kept beside the record can never be read again (retiredNames).
        for name in retiredNames {
            _ = container.appendingPathComponent(name).withUnsafeFileSystemRepresentation { unlink($0!) }
        }
        // The rename is in place; make it durable too, so a power loss right after a put cannot bring the
        // previous record back under an app that was told this one is cached.
        let dirFD: Int32 = container.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_CLOEXEC) }
        guard dirFD >= 0 else { throw WriteFailure.posix(errno: errno) }
        let synced = fullSync(dirFD)
        close(dirFD)
        if synced != 0 { throw WriteFailure.posix(errno: synced) }
    }

    // T-MAC-26c item 3: on macOS plain fsync hands the data to the drive without asking it to flush its own
    // cache; F_FULLFSYNC does (fcntl(2), "F_FULLFSYNC"). A file system that does not support it (it fails
    // with ENOTSUP or EINVAL, e.g. some network or FAT volumes) falls back to fsync, so the write never fails
    // for want of the stronger flush. 0, or the errno of the flush that failed.
    private static func fullSync(_ fd: Int32) -> Int32 {
        if fcntl(fd, F_FULLFSYNC) == 0 { return 0 }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { return code }
        return fsync(fd) == 0 ? 0 : errno
    }

    // MARK: Read

    // What the record file holds.
    private enum Slot {
        case absent
        case unreadable
        case corrupt
        case record(Record)
    }

    private static func load(_ file: URL) -> Slot {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return .absent
        } catch {
            return .unreadable
        }
        guard let record = decode(data) else { return .corrupt }
        return .record(record)
    }

    // MARK: Discard

    // Removes the record and the files earlier builds kept beside it (retiredNames). An absent file is
    // success.
    @discardableResult
    public static func discard(container: URL? = nil) -> Discard {
        guard let container = container ?? AppGroup.defaultContainer() else { return .notNeeded }
        var outcome = Discard.removed
        for file in [url(in: container)] + retiredNames.map({ container.appendingPathComponent($0) }) {
            do {
                try FileManager.default.removeItem(at: file)
            } catch CocoaError.fileNoSuchFile {
                // Absent: nothing to remove.
            } catch {
                if outcome == .removed { outcome = .failed(errno: posixCode(of: error)) }
            }
        }
        return outcome
    }

    // MARK: The record

    static func encode(_ config: Data, killSwitch: Bool, account: Data, putter: uid_t) -> Data {
        var data = Data(capacity: headerLength + config.count)
        data.append(magic)
        data.append(formatVersion)
        data.append(killSwitch ? 1 : 0)
        var uid = UInt32(putter).bigEndian
        withUnsafeBytes(of: &uid) { data.append(contentsOf: $0) }
        data.append(account)
        var length = UInt32(clamping: config.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(sha256(config))
        data.append(config)
        return data
    }

    // nil: not the version-4 shape — short, wrong magic, another version, flags other than 0 or 1, no config,
    // a length that is not the rest of the record, or a digest that does not match the bytes.
    static func decode(_ data: Data) -> Record? {
        let bytes = Data(data)   // index from 0 whatever slice was passed
        guard bytes.count > headerLength,
              bytes.prefix(4) == magic,
              bytes[4] == formatVersion,
              bytes[5] <= 1 else { return nil }
        let putter = bytes[6..<10].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let accountEnd = 10 + accountLength
        let account = Data(bytes[10..<accountEnd])
        let length = bytes[accountEnd..<(accountEnd + 4)].reduce(0) { ($0 << 8) | Int($1) }
        let digest = bytes[(accountEnd + 4)..<headerLength]
        let config = Data(bytes[headerLength...])
        guard config.count == length, sha256(config) == digest else { return nil }
        return Record(config: config, killSwitch: bytes[5] == 1, account: account, putter: uid_t(putter))
    }

    static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: digestLength)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return Data(digest)
    }

    private static func posixCode(of error: Error) -> Int32? {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        return (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
            .flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
    }
}

extension TunnelConfigCache.ReadOutcome {
    // The start runs (a config came back).
    var ran: Bool {
        if case .config = self { return true }
        return false
    }
}
#endif
