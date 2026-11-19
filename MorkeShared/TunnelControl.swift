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

// MARK: - TunnelControl (T-MAC-26h, macOS only)
//
// THE APP'S ONE CHANNEL INTO THE SYSTEM EXTENSION (P84 points 1 and 2). The extension publishes a Mach service,
// NEMachServiceName in Config/MorkeTunnel-macOS-Info.plist (`$(MORKE_APP_GROUP).tunnel`, the same string as
// `machServiceName` below in each configuration), and answers four requests on it, each with a reply:
//   • put    — cache this Connect's config as the Mac's one record (TunnelConfigCache), with the Kill Switch the
//              Connect saved and the hash of the account it is for. Sent before every in-app start; the app
//              starts the tunnel, and arms on-demand, only after the reply says it is cached;
//   • setKillSwitch — the Kill Switch changed (Settings, Network Configuration, its confirm), so the record's flag,
//              which alone chooses the start's TUN stack, follows it (the maintainer, 2026-11-17, «Как на iOS, с
//              XPC»; TunnelConfigCache's header). ON is sent and answered before the app saves includeAllNetworks
//              on, OFF after it saved it off;
//   • revoke — discard the record when the caller's macOS user put it: sign-out, Reset VPN profile, account
//              deletion, a lapse;
//   • state  — whether a record a start would run is held, the hash of its account, and whether the caller's
//              macOS user put it. Never a config byte: nothing of the secret ever leaves the extension.
// This replaces T-MAC-26b's provider messages (a handover to an idle session right before every start, the one
// start shape that ever reset, P84 § 03) and is what Apple's DTS describes for a system extension: "most
// products use XPC for their communication. In the sysex, publish a named XPC endpoint by setting the
// NEMachServiceName property" (forum thread 800887).
//
// WHO MAY CALL. The endpoint is global: "Any process on the system can open a connection to it. Your XPC
// listener must be prepared for this" (the same thread). So the listener carries a code-signing requirement on
// its client — our app's bundle identifier, signed by our team through Apple's CA (`clientRequirement`) — set
// with -[NSXPCListener setConnectionCodeSigningRequirement:], and a peer that does not match "is automatically
// rejected before consulting the delegate" (NSXPCConnection.h, MacOSX27.2.sdk). The app sets the mirror
// requirement on its own connection (`serviceRequirement`), so it never hands the config to anything but our
// extension, and looks the name up in the privileged bootstrap (NSXPCConnectionPrivileged), where the system
// extension's service lives.
//
// WHAT THE EXTENSION KNOWS OF THE CALLER is the peer's effective uid (NSXPCConnection.effectiveUserIdentifier),
// taken from the connection, never from the request: it names the macOS user whose app put the record, and
// scopes a revoke to that user.
//
// SERIAL. Every request runs on `queue`, as the extension's start-time read does, so a put, a revoke and a
// start's read never interleave on the file, and the exit after a stop (P84 point 0) never cuts a request in
// half.
@objc(MorkeTunnelControl)
public protocol TunnelControlXPC {
    // Cache `config` as the record, with the Kill Switch the Connect saved. `account`: TunnelControl.accountHash of
    // the account the Connect is for. Replies with a PutReply raw value.
    func put(config: Data, killSwitch: Bool, account: Data, reply: @escaping (Int) -> Void)
    // Set the record's Kill Switch flag. Replies with a KillSwitchReply raw value.
    func setKillSwitch(on: Bool, reply: @escaping (Int) -> Void)
    // Discard the record when the caller's macOS user put it, or nothing can read it. Replies with a
    // RevokeReply raw value.
    func revoke(reply: @escaping (Int) -> Void)
    // Replies (held, the record's account hash or nil, whether the caller's macOS user put it).
    func state(reply: @escaping (Bool, Data?, Bool) -> Void)
}

public nonisolated enum TunnelControl {

    // The extension's NEMachServiceName: `$(MORKE_APP_GROUP).tunnel`, so each variant (P75) has its own.
    public static let machServiceName = AppGroup.appGroupID + ".tunnel"

    // The team every Morke binary is signed by (DEVELOPMENT_TEAM, project.pbxproj).
    public static let teamIdentifier = "VM3XX8889Q"

    // The Mac app's bundle identifier, chosen at compile time as AppGroup.appGroupID is (P75): the Debug build is
    // "Morke Dev", its own app beside the Release Morke, with its own extension and Mach service.
    #if DEBUG
    public static let appBundleIdentifier = "tech.twodice.morke.dev"
    #else
    public static let appBundleIdentifier = "tech.twodice.morke"
    #endif

    // What the extension's listener requires of a client: our app, signed by our team. `anchor apple generic`
    // covers both the Developer ID (Release) and the Apple Development (Debug) certificate, whose leaf names the
    // team in its subject's OU. Release also requires a Developer ID Application leaf (Apple's marker OID
    // 1.2.840.113635.100.6.1.13), so a development-signed build of the same bundle identifier — debuggable, with
    // get-task-allow — is no client of a shipped extension.
    public static let clientRequirement = requirement(identifier: appBundleIdentifier)

    // What the app requires of the service it reaches: our system extension, signed by our team (in Release,
    // with a Developer ID leaf, as above).
    public static let serviceRequirement = requirement(identifier: TunnelExtensionConstants.bundleID)

    static func requirement(identifier: String) -> String {
        let signed = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        #if DEBUG
        return signed
        #else
        return signed + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        #endif
    }

    public static func interface() -> NSXPCInterface {
        NSXPCInterface(with: TunnelControlXPC.self)
    }

    // Every request, and the extension's start-time read of the record, run here (the header's SERIAL).
    public static let queue = DispatchQueue(label: "tech.twodice.morke.tunnel-control")

    // The account a record is for, as the record and `state` carry it: a SHA-256 of the account id behind a
    // fixed label, so the value names no account id and is no join key with any other digest of it (the
    // analytics container's, AnalyticsLedger). nil (no session) hashes as the empty id.
    public static func accountHash(_ accountID: String?) -> Data {
        TunnelConfigCache.sha256(Data(("morke.macos.tunnel-account\u{0}" + (accountID ?? "")).utf8))
    }

    // What `state` answers.
    public struct State: Sendable, Equatable {
        public let held: Bool
        public let account: Data?
        public let putByCaller: Bool

        public init(held: Bool, account: Data?, putByCaller: Bool) {
            self.held = held
            self.account = account
            self.putByCaller = putByCaller
        }
    }

    // The put's reply, as it travels.
    public enum PutReply: Int, Sendable, Equatable {
        case cached        = 0
        case malformed     = 1
        case invalidConfig = 2
        case writeFailed   = 3

        public init(_ outcome: TunnelConfigCache.PutOutcome) {
            switch outcome {
            case .cached:                    self = .cached
            case .refused(.malformed, _):     self = .malformed
            case .refused(.invalidConfig, _): self = .invalidConfig
            case .refused(.writeFailed, _):   self = .writeFailed
            }
        }
    }

    // The revoke's reply, as it travels. Every answer but `failed` means no record of the caller's is left.
    public enum RevokeReply: Int, Sendable, Equatable {
        case removed          = 0
        case nothingToRemove  = 1
        case keptAnotherUsers = 2
        case failed           = 3

        public init(_ outcome: TunnelConfigCache.RevokeOutcome) {
            switch outcome {
            case .removed:          self = .removed
            case .nothingToRemove:  self = .nothingToRemove
            case .keptAnotherUsers: self = .keptAnotherUsers
            case .failed:           self = .failed
            }
        }

        public var leavesNothingOfTheCallers: Bool { self != .failed }
    }

    // The Kill Switch request's reply, as it travels. Every answer but `failed` means no start can run the record
    // on a stack other than the one the app said.
    public enum KillSwitchReply: Int, Sendable, Equatable {
        case set         = 0
        case nothingHeld = 1
        case failed      = 2

        public init(_ outcome: TunnelConfigCache.KillSwitchOutcome) {
            switch outcome {
            case .set:         self = .set
            case .nothingHeld: self = .nothingHeld
            case .failed:      self = .failed
            }
        }

        public var recordAgrees: Bool { self != .failed }
    }

    // What the extension logs, as a constant each (TunnelControlListener's `report`). No value, no uid.
    public enum Event: Sendable, Equatable {
        case accepted
        case put(TunnelConfigCache.PutOutcome)
        case revoke(TunnelConfigCache.RevokeOutcome)
        case killSwitch(on: Bool, TunnelConfigCache.KillSwitchOutcome)
        case state(held: Bool)
    }

    // MARK: The exit after a stop (P84 point 0)
    //
    // The provider process ends after every stop on macOS, as Proton's system extension and WireGuard's macOS
    // provider do ("The system does not reliably reap provider processes"; WireGuard: Apple bug 32073323), so the
    // next start, put or provider message lands on a fresh process. The record is a file, so nothing is lost.
    // The exit comes `exitDelayAfterStop` after stopTunnel's completion handler (returning from it is what
    // acknowledges the stop) and is skipped when a start arrived in between: a new tunnel in this process is
    // never killed for the one that just stopped.
    //
    // WHAT COUNTS AS A START (T-MAC-26hb). P78j (2026-11-17) caught a server switch whose new start had its provider
    // CREATED in the same millisecond as the exit fired, before that provider's startTunnel ran — the only place a
    // start was noted — so the exit killed it and nesessionmanager sat in `Starting` with no provider until a Stop.
    // A start is now noted at the three points it can be seen in this process, the earliest first:
    //   • a cached PUT (TunnelControlService.put): every in-app Connect puts before it starts, and the put and the
    //     exit both run on `queue`, so one comes wholly before the other. Either the put notes the start and the
    //     exit is skipped, or the exit runs first, the put's connection is interrupted, the app sends it again on
    //     a fresh connection (TunnelControlChannel's one retry), launchd starts a fresh process for it, and the
    //     start lands there. No timing is guessed;
    //   • the provider's INIT (PacketTunnelProvider.init): a start from anything but the app — on-demand, System
    //     Settings — creates its provider before it calls startTunnel;
    //   • startTunnel, as before.
    // And the exit's check and the exit itself are one step under the counter's lock (exitUnlessStarted), so a note
    // cannot land between them. What is left is a start that nesessionmanager has sent to this process and whose
    // provider is not yet created when the exit runs: the time NE's own dispatch takes, not 500 ms.
    public static let exitDelayAfterStop: DispatchTimeInterval = .milliseconds(500)
    public static let providerStarts = StartCounter()

    public final class StartCounter: @unchecked Sendable {
        // @unchecked: the one mutable field is read and written only under `lock`.
        private let lock = NSLock()
        private var starts = 0

        public init() {}

        // A start is on its way in this process: a cached put, the provider's init, startTunnel.
        public func noteStart() {
            lock.lock(); starts += 1; lock.unlock()
        }

        // stopTunnel: where the count stood when this stop completed.
        public func mark() -> Int {
            lock.lock(); defer { lock.unlock() }
            return starts
        }

        // The exit's check: no start since `mark`.
        public func noStart(since mark: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return starts == mark
        }

        // The exit after a stop: `exit` runs only when no start was noted since `mark`, and under the lock, so no
        // note lands between the check and the exit. Answers whether it ran (it never returns in the extension,
        // where `exit` ends the process).
        @discardableResult
        public func exitUnlessStarted(since mark: Int, exit: () -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard starts == mark else { return false }
            exit()
            return true
        }
    }
}

// MARK: - The extension's side

// One per accepted connection: the requests of one client, bound to that client's uid.
public final class TunnelControlService: NSObject, TunnelControlXPC, Sendable {
    private let caller: uid_t
    private let container: URL?
    private let starts: TunnelControl.StartCounter
    private let report: @Sendable (TunnelControl.Event) -> Void

    public init(caller: uid_t, container: URL? = nil, starts: TunnelControl.StartCounter = TunnelControl.providerStarts,
                report: @escaping @Sendable (TunnelControl.Event) -> Void) {
        self.caller = caller
        self.container = container
        self.starts = starts
        self.report = report
    }

    public func put(config: Data, killSwitch: Bool, account: Data, reply: @escaping (Int) -> Void) {
        // T-MAC-26hb: a cached put is a Connect whose start follows, noted on `queue` with the write, so the exit a
        // stop scheduled (on the same queue) either ran before this put or sees the note (StartCounter's WHAT COUNTS
        // AS A START). A refused put starts nothing, so it notes nothing.
        let outcome = TunnelControl.queue.sync {
            let outcome = TunnelConfigCache.acceptPut(config: config, killSwitch: killSwitch, account: account,
                                                      putter: caller, container: container)
            if outcome == .cached { starts.noteStart() }
            return outcome
        }
        report(.put(outcome))
        reply(TunnelControl.PutReply(outcome).rawValue)
    }

    public func revoke(reply: @escaping (Int) -> Void) {
        let outcome = TunnelControl.queue.sync {
            TunnelConfigCache.acceptRevoke(caller: caller, container: container)
        }
        report(.revoke(outcome))
        reply(TunnelControl.RevokeReply(outcome).rawValue)
    }

    public func setKillSwitch(on: Bool, reply: @escaping (Int) -> Void) {
        let outcome = TunnelControl.queue.sync {
            TunnelConfigCache.acceptKillSwitch(on, container: container)
        }
        report(.killSwitch(on: on, outcome))
        reply(TunnelControl.KillSwitchReply(outcome).rawValue)
    }

    public func state(reply: @escaping (Bool, Data?, Bool) -> Void) {
        let state = TunnelControl.queue.sync {
            TunnelConfigCache.state(caller: caller, container: container)
        }
        report(.state(held: state.held))
        reply(state.held, state.account, state.putByCaller)
    }
}

// Configures each connection the listener's requirement let through: the interface, and a service bound to the
// peer's uid.
public final class TunnelControlListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let container: URL?
    private let report: @Sendable (TunnelControl.Event) -> Void

    public init(container: URL? = nil, report: @escaping @Sendable (TunnelControl.Event) -> Void) {
        self.container = container
        self.report = report
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = TunnelControl.interface()
        connection.exportedObject = TunnelControlService(
            caller: connection.effectiveUserIdentifier, container: container, report: report
        )
        connection.resume()
        report(.accepted)
        return true
    }
}

// The listener and its delegate (NSXPCListener holds its delegate weakly), with the client requirement set
// before anything can connect. The extension makes one on its Mach service (MorkeTunnelMac/main.swift); the
// tests make anonymous ones.
public final class TunnelControlListener {
    public let listener: NSXPCListener
    private let delegate: TunnelControlListenerDelegate

    public init(
        listener: NSXPCListener,
        clientRequirement: String,
        container: URL? = nil,
        report: @escaping @Sendable (TunnelControl.Event) -> Void = { _ in }
    ) {
        self.listener = listener
        self.delegate = TunnelControlListenerDelegate(container: container, report: report)
        listener.setConnectionCodeSigningRequirement(clientRequirement)
        listener.delegate = delegate
    }

    // The extension's: its NEMachServiceName, our app only.
    public static func machService(report: @escaping @Sendable (TunnelControl.Event) -> Void) -> TunnelControlListener {
        TunnelControlListener(
            listener: NSXPCListener(machServiceName: TunnelControl.machServiceName),
            clientRequirement: TunnelControl.clientRequirement,
            report: report
        )
    }

    public func resume() { listener.resume() }
    public func invalidate() { listener.invalidate() }
}
#endif
