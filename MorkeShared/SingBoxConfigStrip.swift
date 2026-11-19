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

// MARK: - SingBoxConfigStrip (T-ROUTE-8)
//
// The Smart merge taken back off a config: the exact inverse of `SingBoxConfigMerge.apply`, in the one
// module both processes link. ONE implementation, two callers:
//   • the app, through `SingBoxConfigMerge.revert` (P15's leaving-Smart reify, T-ROUTE-6's fallback);
//   • the tunnel, when the engine refuses a start whose config names a local rule-set: it strips the
//     merge and starts once more with what is left, the full tunnel (PacketTunnelProvider, T-ROUTE-8).
//     MorkeTunnel links MorkeShared and never MorkeServices, which is why this is not in
//     SingBoxConfigMerge.swift.
//
// What it removes, each piece recognised by its own shape, never by position:
//  • every rule that is exactly `{rule_set, action: "route", outbound: "direct"}` and whose tags all
//    name entries of the shape below — matched by `action`, outbound and tags, as `apply` matches it;
//  • the `rule_set` entries those rules name, each exactly `{type: "local", tag, format: "binary",
//    path}` — the server cannot send a local set, since it cannot know a path on this device;
//  • `experimental.cache_file` when it is exactly `{enabled: true, path: cachePath}`.
// A container left empty by the removal is dropped too, because `apply` created it: the server sends
// neither `route.rule_set` nor `experimental` (frozen contract), and its `route.rules` is never empty.
// The `direct` OUTBOUND stays — the server sends one anyway, and a server-sent outbound is not ours to
// remove. `route.final` is never read or written, so what is left sends everything to the proxy.
//
// Contract (pinned by tests): `strip(apply(x))` equals `x` as JSON on both server rule shapes, with and
// without the gVisor rewrite (which touches only `inbounds`), and a config carrying none of the above
// is nil — nothing of ours, so the caller keeps its bytes exactly.
//
// Foundation only, no state, nothing logged: the tunnel runs it inside the Packet-Tunnel memory budget,
// and only on a start that has already failed.
public nonisolated enum SingBoxConfigStrip {

    // The outbound tag the merge's rule routes to (`SingBoxConfigMerge.directTag`).
    public static let directTag = "direct"

    // Where the merge points sing-box's cache_file: the App Group container, the one directory
    // TunnelWorkspace.wipe() clears (api.md § The `experimental.cache_file` contract). The app and the
    // iOS appex resolve the same container, so both callers derive the same path.
    public static var defaultCachePath: String {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.appGroupID)?
            .appendingPathComponent("cache.db")
            .path ?? ""
    }

    public struct Stripped: Sendable, Equatable {
        // The config without the merge.
        public let config: SingBoxConfig
        // The `path` of each local rule-set entry removed, in config order. Empty when only the
        // cache_file was ours: then no list was in the config.
        public let ruleSetPaths: [String]
    }

    public enum Failure: Error, Sendable {
        case malformedConfig      // the raw bytes are not a JSON object
        case serializationFailed  // re-serialization of the stripped config failed
    }

    // nil: nothing of ours in `config`.
    public static func strip(_ config: SingBoxConfig, cachePath: String = defaultCachePath) throws -> Stripped? {
        guard var root = (try? JSONSerialization.jsonObject(with: config.raw)) as? [String: Any] else {
            throw Failure.malformedConfig
        }
        var changed = false
        var ruleSetPaths: [String] = []

        // 1. The appended rules and the local entries they name.
        if var route = root["route"] as? [String: Any] {
            var ruleSetEntries = route["rule_set"] as? [[String: Any]] ?? []
            let localTags = Set(ruleSetEntries.filter(isLocalRuleSet).compactMap { $0["tag"] as? String })
            var rules = route["rules"] as? [[String: Any]] ?? []
            var removedTags = Set<String>()
            rules.removeAll { rule in
                guard Set(rule.keys) == ["rule_set", "action", "outbound"],
                      (rule["action"] as? String) == "route",
                      (rule["outbound"] as? String) == directTag,
                      let tags = rule["rule_set"] as? [String], !tags.isEmpty,
                      localTags.isSuperset(of: tags) else { return false }
                removedTags.formUnion(tags)
                return true
            }
            if !removedTags.isEmpty {
                let isRemoved = { [removedTags] (entry: [String: Any]) in
                    isLocalRuleSet(entry) && removedTags.contains(entry["tag"] as? String ?? "")
                }
                ruleSetPaths = ruleSetEntries.filter(isRemoved).compactMap { $0["path"] as? String }
                ruleSetEntries.removeAll(where: isRemoved)
                route["rules"] = rules.isEmpty ? nil : rules
                route["rule_set"] = ruleSetEntries.isEmpty ? nil : ruleSetEntries
                root["route"] = route.isEmpty ? nil : route
                changed = true
            }
        }

        // 2. cache_file, only when it is exactly the one `apply` writes.
        if var experimental = root["experimental"] as? [String: Any],
           let cacheFile = experimental["cache_file"] as? [String: Any],
           Set(cacheFile.keys) == ["enabled", "path"],
           (cacheFile["enabled"] as? Bool) == true,
           (cacheFile["path"] as? String) == cachePath {
            experimental["cache_file"] = nil
            root["experimental"] = experimental.isEmpty ? nil : experimental
            changed = true
        }

        guard changed else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: root) else {
            throw Failure.serializationFailed
        }
        return Stripped(config: SingBoxConfig(raw: data), ruleSetPaths: ruleSetPaths)
    }

    // The entry `apply` writes for one list, and nothing else: `{type: "local", tag, format: "binary",
    // path}`.
    private static func isLocalRuleSet(_ entry: [String: Any]) -> Bool {
        Set(entry.keys) == ["type", "tag", "format", "path"]
            && (entry["type"] as? String) == "local"
            && (entry["format"] as? String) == "binary"
    }
}
