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

//
//  Pure C helpers extracted from ExtensionPlatformInterface.m so the trickiest
//  bit / ABI math can be unit-tested off-device (the Network Extension itself
//  never runs in the Simulator — see T-TEST-UNIT-12). Foundation / libbox-free
//  on purpose: every function takes plain byte / flag inputs and returns a plain
//  integer type. The call site in ExtensionPlatformInterface.m maps the returned
//  interface-type code back to the LibboxInterfaceType* constants.
//

#ifndef MORKE_TUNNEL_NET_HELPERS_H
#define MORKE_TUNNEL_NET_HELPERS_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/socket.h>

#ifdef __cplusplus
extern "C" {
#endif

// Interface-type codes returned by morke_interface_type_for_name().
// libbox-free: ExtensionPlatformInterface.m maps these to the matching
// LibboxInterfaceType* constants at the call site.
typedef enum {
    MorkeInterfaceTypeOther    = 0,
    MorkeInterfaceTypeWIFI     = 1,
    MorkeInterfaceTypeCellular = 2,
} MorkeInterfaceType;

// Returns true for a real physical interface; false for loopback, down, and
// Apple-internal / tunnel interfaces (utun/awdl/llw/anpi/stf/gif/bridge/ipsec).
// `flags` are the getifaddrs ifa_flags bitset (IFF_*).
bool morke_is_physical_interface(const char *name, unsigned int flags);

// Maps an iOS interface name prefix to a MorkeInterfaceType code:
// en* -> WIFI, pdp_ip* / rmnet* -> Cellular, otherwise Other.
int32_t morke_interface_type_for_name(const char *name);

// Converts an AF_INET netmask sockaddr to a prefix length (0..32).
// Reproduces the Darwin getifaddrs sa_len truncation: trailing all-zero mask
// bytes may be dropped, so bytes are read only within sa_len and missing
// trailing bytes are treated as 0. Returns 0 for NULL / non-AF_INET input.
int morke_ipv4_netmask_prefix(const struct sockaddr *netmask);

// Converts an AF_INET6 netmask sockaddr to a prefix length (0..128), with the
// same sa_len truncation handling as the IPv4 variant. The 16-byte mask is read
// at byte offset 8 (sin6_addr) to avoid the private <netinet6/in6.h> module.
// Returns 0 for NULL / non-AF_INET6 input.
int morke_ipv6_netmask_prefix(const struct sockaddr *netmask);

// Returns true if the IPv6 address carried by `addr` is link-local (fe80::/10).
// The 16-byte address is read at byte offset 8 of the sockaddr (sin6_addr),
// matching the manual layout parse in ExtensionPlatformInterface.m.
// Returns false for NULL / non-AF_INET6 input / a sockaddr too short to hold
// sin6_addr[0..1] (sa_len < 10).
bool morke_ipv6_is_link_local(const struct sockaddr *addr);

// ── P9g: the tunnel's half of the analytics (T-DESIGN-24) ──────────────────────
// Called from TunnelAnalytics.swift; covered by MorkeTunnelTests' TunnelAnalyticsHelpersTests.
// Both pure.

// Bytes moved between two readings of one of the engine's running totals
// (libbox's uplinkTotal / downlinkTotal, since P9gb). A reading BELOW the
// previous one is a total that restarted — a new engine starts from zero — so
// the bytes are the new reading, never current - previous modulo 2^64, which
// would invent ~16 EiB.
uint64_t morke_counter_delta(uint64_t previous, uint64_t current);

// Whether a stop is a Kill Switch block: includeAllNetworks on, and a stop
// reason that means the tunnel FAILED under the user — so the OS held their
// traffic — rather than one the user, the configuration, an app update, a
// higher-priority VPN or sleep asked for. `stop_reason` is the
// NEProviderStopReason raw value; an unknown value is not a block.
bool morke_stop_is_kill_switch_block(bool include_all_networks, long stop_reason);

#ifdef __cplusplus
}
#endif

#endif /* MORKE_TUNNEL_NET_HELPERS_H */
