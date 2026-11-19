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

// MARK: - SingBoxGVisorStack (T-CFG-17, moved here by T-MAC-26)
//
// The kill switch sets `includeAllNetworks`, and sing-box's `system` and `mixed` TUN stacks are
// incompatible with it (libbox's `tun.NewStack` returns `ErrIncludeAllNetworks`); only gVisor forwards
// correctly then. The backend pins `stack: "system"`, so with the kill switch on every `tun` inbound's
// `stack` is rewritten to `"gvisor"`. The reasoning in full is SingBoxKillSwitchStack's header.
//
// ONE implementation, in the one module both processes link, as SingBoxConfigStrip did for T-ROUTE-8:
//   • the app, through `SingBoxKillSwitchStack.applyingGVisorStack` (iOS: connect, storeConfig and the
//     kill-switch reify rewrite the config stored in the Keychain);
//   • the macOS system extension, at START (T-MAC-26): the Mac's config now sits in the extension's
//     root-only cache (TunnelConfigCache), out of the app's reach while the tunnel is down, so the
//     extension rewrites the bytes it is about to run, from the profile's own `includeAllNetworks`
//     (`forStart`). The engine's stack and the OS policy then agree on every start path.
//
// Pure: only the `stack` value of `tun` inbounds changes, every other field and the inbound order are
// kept. Idempotent: an already-gVisor config (or one with no `tun` inbound) comes back byte for byte.
// Foundation only, no state, nothing logged: the extension runs it inside the Packet-Tunnel memory
// budget, once per start and only with the kill switch on.
public nonisolated enum SingBoxGVisorStack {

    // The only TUN stack compatible with `includeAllNetworks` (sing-tun: system/mixed are rejected).
    public static let stack = "gvisor"

    public enum Failure: Error, Sendable {
        case malformedConfig      // the raw bytes are not a JSON object
        case serializationFailed  // re-serialization of the rewritten config failed
    }

    // Returns a config whose every `tun` inbound uses the gVisor stack, or the input untouched when no
    // `tun` inbound needs rewriting, so its bytes are preserved exactly.
    public static func applying(to config: SingBoxConfig) throws -> SingBoxConfig {
        guard var root = (try? JSONSerialization.jsonObject(with: config.raw)) as? [String: Any] else {
            throw Failure.malformedConfig
        }

        var inbounds = root["inbounds"] as? [[String: Any]] ?? []
        var changed = false
        for index in inbounds.indices {
            guard (inbounds[index]["type"] as? String) == "tun" else { continue }
            if (inbounds[index]["stack"] as? String) != stack {
                inbounds[index]["stack"] = stack
                changed = true
            }
        }

        // Nothing to rewrite (no tun inbound, or already gVisor): return the input untouched so the
        // bytes are preserved exactly.
        guard changed else { return config }

        root["inbounds"] = inbounds
        guard let data = try? JSONSerialization.data(withJSONObject: root) else {
            throw Failure.serializationFailed
        }
        return SingBoxConfig(raw: data)
    }

    // The extension's decision at start: the rewrite when the profile it was started with carries
    // `includeAllNetworks`, the config byte for byte otherwise (the server-pinned stack, and the memory
    // profile the backend chose for it).
    public static func forStart(_ config: SingBoxConfig, includeAllNetworks: Bool) throws -> SingBoxConfig {
        includeAllNetworks ? try applying(to: config) : config
    }
}
