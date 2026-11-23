// Entry point for the Morke packet tunnel packaged as a macOS System Extension (T-MAC-2 Phase B).
//
// A macOS system extension is a standalone executable, unlike an iOS app extension (a plug-in the
// host loads via NSExtensionPrincipalClass). It must enter NetworkExtension's system-extension mode
// itself: startSystemExtensionMode() reads this bundle's Info.plist NEProviderClasses map,
// instantiates the @objc(PacketTunnelProvider) class (compiled in from the shared
// MorkeTunnel/PacketTunnelProvider.swift), and hands control to the NE runtime.
//
// macOS-sysext-ONLY: compiled solely by the "MorkeTunnel (macOS)" target. The iOS appex must NOT
// include a main entry point, so this file lives OUTSIDE the synchronized MorkeTunnel/ folder and is
// referenced explicitly by the macOS target alone (mirrors how Config/MorkeTunnel-macOS-Info.plist is
// kept out of the iOS appex). Entry-point pattern verified against sing-box-for-apple's
// SystemExtension/main.swift.
//
// T-MAC-26h — THE APP'S CHANNEL (P84 points 1 and 2). Before NE takes over, this process publishes its
// NEMachServiceName (Config/MorkeTunnel-macOS-Info.plist) as an XPC listener that accepts only our signed app
// (TunnelControl.clientRequirement, set with -[NSXPCListener setConnectionCodeSigningRequirement:]; a client that
// does not match is rejected before the delegate sees it) and answers put, revoke and state (TunnelControl,
// TunnelConfigCache). Proton's system extension does the same in its main.swift. That launchd starts this process
// for a connection while no tunnel runs (after a reboot, or after the exit that follows every stop,
// PacketTunnelProvider.stopTunnel) is not documented by Apple and is the Mac run's to measure; when it does not,
// the app's put finds no listener and the Connect fails, starting nothing.
//
// Each line below is a constant: never a config byte, a length, an account hash or a uid.

import Foundation
import NetworkExtension
import OSLog
import MorkeShared

// Held for the process's lifetime: NSXPCListener keeps its delegate weakly, and TunnelControlListener holds both.
// The report runs on XPC's queues, so it makes its own Logger rather than reach a top-level value.
let tunnelControl = TunnelControlListener.machService { event in
    let controlLog = Logger(subsystem: MorkeLog.subsystem, category: "tunnel")
    switch event {
    case .accepted:
        controlLog.notice("xpc: a connection from the app accepted (T-MAC-26h)")
    case .put(.cached):
        controlLog.notice("xpc: put — config cached for every start (T-MAC-26h)")
    case .put(.refused(let reason, let code?)):
        controlLog.error("xpc: put refused — \(reason.rawValue, privacy: .public), errno=\(code, privacy: .public) (T-MAC-26h)")
    case .put(.refused(let reason, nil)):
        controlLog.error("xpc: put refused — \(reason.rawValue, privacy: .public) (T-MAC-26h)")
    case .revoke(.removed):
        controlLog.notice("xpc: revoke — the config cache is gone (T-MAC-26h)")
    case .revoke(.nothingToRemove):
        controlLog.notice("xpc: revoke — no cached config, nothing to remove (T-MAC-26h)")
    case .revoke(.keptAnotherUsers):
        controlLog.notice("xpc: revoke — the cached config is another macOS user's, kept (T-MAC-26h)")
    case .revoke(.failed(let code?)):
        controlLog.error("xpc: revoke — the config cache could not be removed, errno=\(code, privacy: .public) (T-MAC-26h)")
    case .revoke(.failed(nil)):
        controlLog.error("xpc: revoke — the config cache could not be removed, errno unavailable (T-MAC-26h)")
    case .killSwitch(let on, .set):
        controlLog.notice("xpc: Kill Switch \(on ? "on" : "off", privacy: .public) — the cached config's start follows it (T-MAC-26h)")
    case .killSwitch(let on, .nothingHeld):
        controlLog.notice("xpc: Kill Switch \(on ? "on" : "off", privacy: .public) — no cached config, nothing to set (T-MAC-26h)")
    case .killSwitch(let on, .failed(let code?)):
        controlLog.error("xpc: Kill Switch \(on ? "on" : "off", privacy: .public) — the cached config could not be updated, errno=\(code, privacy: .public) (T-MAC-26h)")
    case .killSwitch(let on, .failed(nil)):
        controlLog.error("xpc: Kill Switch \(on ? "on" : "off", privacy: .public) — the cached config could not be updated, errno unavailable (T-MAC-26h)")
    case .state(held: true):
        controlLog.notice("xpc: state — a config is cached (T-MAC-26h)")
    case .state(held: false):
        controlLog.notice("xpc: state — no config a start would run (T-MAC-26h)")
    }
}
tunnelControl.resume()
Logger(subsystem: MorkeLog.subsystem, category: "tunnel").notice("xpc: listening on the Mach service, our app only (T-MAC-26h)")

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
