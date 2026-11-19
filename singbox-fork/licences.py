#!/usr/bin/env python3
"""The Settings licence list, generated from what the binaries actually link (P3 · T-REL-16).

GPLv3 § 4 and the Apache-2.0 / BSD / MIT / MPL-2.0 notice clauses bind every module whose code
ships, not a hand-picked "significant set". This script derives that set and copies each module's
own licence files byte-for-byte, so the next engine change re-derives the list instead of editing
it by hand.

THE ENGINE (MorkeTunnel.appex). Given the PATCHED sing-box tree of BUILD.md § 2 (commit + patch)
and the module cache that tree resolves against:

  1. the linked module set is `go list -deps -json ./experimental/libbox` for GOOS=ios
     GOARCH=arm64 CGO_ENABLED=1 with the exact iOS tags — read out of the patched
     cmd/internal/build_libbox/main.go, never retyped here — plus the gobind glue gomobile
     compiles in (github.com/sagernet/gomobile: bind/seq, internal/mobileinit) and the Go
     standard library (the toolchain's own LICENSE, `go env GOROOT`);
  2. with --libbox, every module is cross-checked against the import-path occurrences in the
     built ios-arm64 `Libbox` (the `strings -a | grep` method P2 used); a module with none is
     reported, never silently dropped — over-attribution harms no one;
  3. each module's top-level LICENSE* / LICENCE* / COPYING* / NOTICE* files are read from its
     module-cache directory. A module with none STOPS the run: that is a compliance question for
     a person, not something to guess.

THE APP (Morke.app + MorkeWidget.appex), with --resolved and --checkouts. The same obligation
applies to the SwiftPM packages linked into the app. Package.resolved names the pins; the licence
files are read from the checkouts SwiftPM made at those revisions (an Xcode build's
`<derivedData>/SourcePackages/checkouts`), and each checkout's HEAD is compared with its pin. Build
the app first — `xcodebuild … -derivedDataPath <dd> build` resolves and checks them out. A pin is
kept only if one of its source targets' module names occurs in a built app binary (--app-binary,
repeatable); a pin with none is build-time only (swift-syntax: it runs inside the compiler as the
macro host and is never linked) and is reported as excluded.

GROUPING. Every distinct text is ONE file, named after the first module that carries it (by module
path), so four sagernet modules sharing one LICENSE bundle it once. An entry lists the files it
reads — its licence plus any NOTICE.

OUTPUT, into --out: `Licences/*.txt`, `licences.json` (the machine-readable manifest: id, display
name, repository, SPDX name, text files and their sha256) and `components.swift.txt`, the literal
the catalogue carries. With --apply <morke-tree> it also replaces the generated `.txt` files in
MorkeKit/Sources/MorkeFeatures/Licences/ (gpl-3.0.txt is the canonical FSF text, not generated,
and is left alone) and the block between the GENERATED markers in Settings/Licences.swift.

Deterministic: the same inputs give byte-identical output. Stdlib only; no network — the module
cache and the checkouts must already be populated (the BUILD.md build and the Xcode build do that).

    python3 licences.py --src <sing-box tree> --libbox <…/ios-arm64/…/Libbox> \
        --resolved Morke.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
        --checkouts <dd>/SourcePackages/checkouts --app-binary <…/Morke.app/Morke.debug.dylib> \
        --app-binary <…/MorkeWidget.appex/MorkeWidget.debug.dylib> --out <dir> [--apply <morke-tree>]
"""
import argparse, hashlib, json, os, re, subprocess, sys

LICENCE_FILE = re.compile(r"^(licen[cs]e|copying|notice)([._-].*)?$", re.IGNORECASE)
PRIMARY = re.compile(r"^(licen[cs]e|copying)", re.IGNORECASE)
BEGIN = "    // BEGIN GENERATED — publish/tunnel-source/singbox-fork/licences.py. Do not edit by hand.\n"
END = "    // END GENERATED\n"
GLUE = "github.com/sagernet/gomobile"


def fail(message):
    sys.exit(f"licences.py: STOP — {message}")


def run(args, cwd, env=None):
    return subprocess.run(args, cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout


# --- the engine ---------------------------------------------------------------------------------

def ios_tags(src):
    """The iOS tag set, read from the patched build script rather than restated here."""
    main = open(os.path.join(src, "cmd/internal/build_libbox/main.go")).read()

    def appended(name):
        found = re.search(rf"{name} = append\({name}, ([^)]*)\)", main)
        if not found:
            fail(f"build_libbox/main.go no longer appends to {name}; re-read the build script")
        return re.findall(r'"([^"]+)"', found.group(1))

    if '"-tags-not-macos=' not in main:
        fail("build_libbox/main.go no longer passes -tags-not-macos; re-read the build script")
    return appended("sharedTags") + appended("darwinTags") + appended("notMemcTags")


def engine_modules(src):
    env = dict(os.environ, GOOS="ios", GOARCH="arm64", CGO_ENABLED="1", GOFLAGS="-mod=readonly",
               GOWORK="off")
    tags = ios_tags(src)
    stream = run(["go", "list", "-deps", "-json", "-tags", ",".join(tags), "./experimental/libbox"],
                 src, env)
    modules, decoder, pos = {}, json.JSONDecoder(), 0
    while True:
        while pos < len(stream) and stream[pos].isspace():
            pos += 1
        if pos == len(stream):
            break
        package, pos = decoder.raw_decode(stream, pos)
        module = package.get("Module")
        if not module:
            continue
        module = module.get("Replace") or module
        modules[module["Path"]] = {"path": module["Path"], "dir": module["Dir"],
                                   "main": bool(module.get("Main"))}
    glue = json.loads(run(["go", "list", "-m", "-json", GLUE], src, env))
    modules[GLUE] = {"path": GLUE, "dir": glue["Dir"], "main": False}
    # The toolchain's own LICENSE. Homebrew moves it from GOROOT (<keg>/libexec) up to the keg root.
    goroot = run(["go", "env", "GOROOT"], src, env).strip()
    for candidate in (goroot, os.path.dirname(goroot)):
        if os.path.isfile(os.path.join(candidate, "LICENSE")):
            modules["std"] = {"path": "std", "dir": candidate, "main": False, "files": ["LICENSE"]}
            break
    else:
        fail(f"the Go toolchain's LICENSE is neither in {goroot} nor beside it")
    return tags, list(modules.values())


def printable_strings(path):
    with open(path, "rb") as fh:
        return b"\n".join(re.findall(rb"[\x20-\x7e]{4,}", fh.read()))


def occurrences(blob, name):
    return len(re.findall(re.escape(name.encode()) + rb"(?![A-Za-z0-9_-])", blob))


def mangled(blob, module):
    # The length prefix bounds the name; what follows is the next mangling token.
    return len(re.findall(rb"(?<![0-9])" + str(len(module)).encode() + re.escape(module.encode()), blob))


# --- the app ------------------------------------------------------------------------------------

def checkout_head(checkout):
    git = os.path.join(checkout, ".git")
    if os.path.isfile(git):
        git = os.path.join(checkout, open(git).read().split(":", 1)[1].strip())
    head = open(os.path.join(git, "HEAD")).read().strip()
    if head.startswith("ref: "):
        head = open(os.path.join(git, head[5:])).read().strip()
    return head


def app_modules(resolved, checkouts, binaries):
    blob = b"\n".join(printable_strings(b) for b in binaries)
    kept, excluded = [], []
    for pin in json.load(open(resolved))["pins"]:
        checkout = os.path.join(checkouts, pin["identity"])
        if not os.path.isdir(checkout):
            fail(f"no checkout for {pin['identity']} under {checkouts}; build the app first")
        if checkout_head(checkout) != pin["state"]["revision"]:
            fail(f"{pin['identity']}: checkout is not at the pinned revision {pin['state']['revision']}")
        sources = os.path.join(checkout, "Sources")
        targets = sorted(t for t in os.listdir(sources) if os.path.isdir(os.path.join(sources, t)))
        # A linked Swift module shows up in mangled symbols as <length><name> ("22ComposableArchitecture");
        # a bare name can also be a path fragment, which proves nothing.
        hits = sum(mangled(blob, t) for t in targets)
        path = re.sub(r"^https?://|\.git$", "", pin["location"])
        record = {"path": path, "dir": checkout, "main": False, "evidence": hits}
        (kept if hits else excluded).append(record)
    return kept, excluded


# --- licences -----------------------------------------------------------------------------------

def licence_files(module):
    if "files" in module:
        names = module["files"]
    else:
        names = sorted(n for n in os.listdir(module["dir"])
                       if LICENCE_FILE.match(n) and os.path.isfile(os.path.join(module["dir"], n)))
    if not names:
        return None
    # The licence first, then NOTICE-type files — the order the reader needs them in.
    return sorted(names, key=lambda n: (not PRIMARY.match(n), n))


def spdx(text):
    t = " ".join(text.split())
    # MPL first: its own text names the GNU licences as "Secondary Licenses".
    if "Mozilla Public License Version 2.0" in t or "Mozilla Public License, v. 2.0" in t:
        return "MPL-2.0"
    if "GNU GENERAL PUBLIC LICENSE" in t.upper() or "GNU General Public License" in t:
        return "GPL-3.0-or-later" if "either version 3" in t or "Version 3" in t else None
    # The permissive families can share one file (klauspost/compress carries BSD, Apache and MIT
    # sections): every family found is named, in the order the file gives them.
    found = []
    if "Apache License" in t and "Version 2.0" in t:
        found.append((t.index("Apache License"), "Apache-2.0 WITH Swift-exception"
                      if "Runtime Library Exception" in t else "Apache-2.0"))
    if "Redistribution and use in source and binary forms" in t:
        found.append((t.index("Redistribution and use"), "BSD-3-Clause"
                      if "Neither the name" in t or "names of its contributors" in t else "BSD-2-Clause"))
    if "Permission is hereby granted, free of charge" in t:
        found.append((t.index("Permission is hereby granted"), "MIT"))
    if "This is free and unencumbered software released into the public domain" in t:
        found.append((0, "Unlicense"))
    return " AND ".join(name for _, name in sorted(found)) or None


def display(path):
    if path == "std":
        return "Go standard library", "go.googlesource.com/go"
    name = re.sub(r"/v[0-9]+$", "", path)
    return re.sub(r"^github\.com/", "", name), path


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def shared_name(owners):
    """A file several modules share is named for what they have in common — `sagernet` for the
    sagernet notice — or, with nothing in common, for its first owner (the stdlib ranks first:
    it is where the Go Authors' text comes from)."""
    if len(owners) == 1:
        return owners[0]
    prefix = os.path.commonprefix(owners)
    if "-" in prefix and not all(o == prefix for o in owners):
        prefix = prefix[:prefix.rindex("-")]
        if prefix:
            return prefix
    return owners[0]


def build(modules):
    missing = [m["path"] for m in modules if licence_files(m) is None]
    if missing:
        fail("no LICENSE / COPYING / NOTICE in: " + ", ".join(sorted(missing)))
    entries, texts, ids = [], {}, set()   # texts: sha256 -> {"bytes", "owners", "suffix"}
    for module in sorted(modules, key=lambda m: "" if m["path"] == "std" else m["path"]):
        name, repository = display(module["path"])
        if module["main"]:
            name = name.split("/")[-1]              # the engine itself reads as "sing-box"
        ident = "go" if module["path"] == "std" else slug(name)
        if ident in ids:
            fail(f"two modules slug to {ident}")
        ids.add(ident)
        digests, kind = [], None
        for filename in licence_files(module):
            data = open(os.path.join(module["dir"], filename), "rb").read()
            digest = hashlib.sha256(data).hexdigest()
            suffix = "" if PRIMARY.match(filename) else "-" + slug(filename.split(".")[0])
            texts.setdefault(digest, {"bytes": data, "owners": [], "suffix": suffix})["owners"].append(ident)
            digests.append(digest)
            kind = kind or (spdx(data.decode("utf-8", "replace")) if PRIMARY.match(filename) else None)
        if kind is None:
            fail(f"{module['path']}: licence not recognised — classify it by hand and extend spdx()")
        entries.append({"id": ident, "name": name, "repository": repository, "licence": kind,
                        "texts": digests})
    # Two different texts can have owners with a prefix in common (pointfreeco's MIT files differ
    # in their copyright years); the second one then falls back to its first owner.
    taken = set()
    for digest in sorted(texts, key=lambda d: (texts[d]["owners"][0], d)):
        text = texts[digest]
        for name in (shared_name(text["owners"]), text["owners"][0]):
            if name + text["suffix"] not in taken:
                text["resource"] = name + text["suffix"]
                break
        else:
            fail(f"no free file name for the text of {', '.join(text['owners'])}")
        taken.add(text["resource"])
    for entry in entries:
        entry["texts"] = [{"resource": texts[d]["resource"], "sha256": d} for d in entry["texts"]]
    # sing-box first — the screen's intro names it — then by name.
    entries.sort(key=lambda e: (e["id"] != "sing-box", e["name"].lower()))
    resources = [t["resource"] for t in texts.values()]
    if len(resources) != len(set(resources)) or "gpl-3.0" in resources:
        fail("two distinct texts would share a file name")
    return entries, texts


def swift_literal(entries):
    def s(value):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    lines = ["    static let components: [Licence] = ["]
    for e in entries:
        texts = ", ".join(f".init(resource: {s(t['resource'])}, sha256: {s(t['sha256'])})"
                          for t in e["texts"])
        lines.append(f"        Licence(id: {s(e['id'])}, name: {s(e['name'])},")
        lines.append(f"                repository: {s(e['repository'])}, licenceName: {s(e['licence'])},")
        lines.append(f"                texts: [{texts}]),")
    lines.append("    ]")
    return "\n".join(lines) + "\n"


def write(out, entries, texts, literal):
    os.makedirs(os.path.join(out, "Licences"), exist_ok=True)
    for text in texts.values():
        with open(os.path.join(out, "Licences", text["resource"] + ".txt"), "wb") as fh:
            fh.write(text["bytes"])
    with open(os.path.join(out, "licences.json"), "w") as fh:
        json.dump(entries, fh, indent=2, sort_keys=True)
        fh.write("\n")
    with open(os.path.join(out, "components.swift.txt"), "w") as fh:
        fh.write(literal)


def apply(tree, texts, literal):
    """Replace the generated block and exactly the files it names — hand-kept entries outside the
    block (gpl-3.0.txt, later T-ROUTE-2's data notices) and their files are never touched."""
    directory = os.path.join(tree, "MorkeKit/Sources/MorkeFeatures/Licences")
    swift = os.path.join(tree, "MorkeKit/Sources/MorkeFeatures/Settings/Licences.swift")
    source = open(swift).read()
    if source.count(BEGIN) != 1 or source.count(END) != 1:
        fail("Licences.swift must carry exactly one GENERATED block")
    head, rest = source.split(BEGIN)
    old, tail = rest.split(END)
    kept = set(re.findall(r'resource: "([^"]+)"', head + tail))
    for resource in set(re.findall(r'resource: "([^"]+)"', old)) - kept:
        path = os.path.join(directory, resource + ".txt")
        if os.path.exists(path):
            os.remove(path)
    for text in texts.values():
        if text["resource"] in kept:
            fail(f"generated file {text['resource']}.txt would overwrite a hand-kept one")
        with open(os.path.join(directory, text["resource"] + ".txt"), "wb") as fh:
            fh.write(text["bytes"])
    with open(swift, "w") as fh:
        fh.write(head + BEGIN + literal + END + tail)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--src", required=True, help="the patched sing-box v1.14.1 tree")
    p.add_argument("--libbox", help="the built ios-arm64 Libbox, for the cross-check")
    p.add_argument("--resolved", help="the app's Package.resolved")
    p.add_argument("--checkouts", help="SourcePackages/checkouts of an Xcode build of the app")
    p.add_argument("--app-binary", action="append", default=[], help="a built app binary (repeatable)")
    p.add_argument("--out", required=True)
    p.add_argument("--apply", metavar="MORKE_TREE")
    a = p.parse_args()

    tags, modules = engine_modules(a.src)
    print(f"engine: tags {','.join(tags)}")
    third_party = [m for m in modules if not m["main"] and m["path"] not in ("std", GLUE)]
    print(f"engine: {len(third_party)} third-party modules + the Go standard library + gobind glue ({GLUE})")
    if a.libbox:
        blob = printable_strings(a.libbox)
        for m in sorted(modules, key=lambda m: m["path"]):
            if m["path"] != "std":
                n = occurrences(blob, m["path"])
                print(f"  {n:6d}  {m['path']}" + ("   ⚠️ no occurrence in the slice" if n == 0 else ""))

    if a.resolved:
        if not (a.checkouts and a.app_binary):
            fail("--resolved needs --checkouts and at least one --app-binary")
        kept, excluded = app_modules(a.resolved, a.checkouts, a.app_binary)
        print(f"app: {len(kept)} linked SwiftPM packages; excluded as not linked: "
              + (", ".join(m["path"] for m in excluded) or "none"))
        modules += kept

    entries, texts = build(modules)
    literal = swift_literal(entries)
    write(a.out, entries, texts, literal)
    print(f"{len(entries)} entries, {len(texts)} distinct licence texts → {a.out}")
    if a.apply:
        apply(a.apply, texts, literal)
        print(f"applied to {a.apply}")


if __name__ == "__main__":
    main()
