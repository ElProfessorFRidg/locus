#!/usr/bin/env python3
"""Writes a Package.swift that runs the LocusTests logic tests on the Mac itself.

The LocusTests target in project.yml is pure Swift — no UIKit, no FFI — so it
doesn't need an iOS simulator, and booting one is most of what the test step
used to spend its time on. The source list is read from project.yml rather than
copied, so the two can't drift: add a file to LocusTests there and it is tested
here too.
"""
import re
import sys

def logic_test_sources(project_yml):
    lines = open(project_yml, encoding="utf-8").read().splitlines()
    try:
        start = lines.index("  LocusTests:")
    except ValueError:
        sys.exit("project.yml has no LocusTests target")
    sources, in_sources = [], False
    for line in lines[start + 1:]:
        if re.match(r"^  \S", line):          # the next target
            break
        if line.strip() == "sources:":
            in_sources = True
            continue
        if in_sources:
            match = re.match(r"^\s+- path: (\S+)\s*$", line)
            if match:
                sources.append(match.group(1))
            elif line.strip() and not line.strip().startswith("#"):
                break                          # settings: and the rest
    if not sources:
        sys.exit("LocusTests lists no sources")
    return sources

def main():
    sources = logic_test_sources("project.yml")
    listed = ",\n                ".join(f'"{s}"' for s in sources)
    open("Package.swift", "w", encoding="utf-8").write(f"""// swift-tools-version:6.0
// Generated in CI by .github/scripts/logic-package.py — not committed.
import PackageDescription

let package = Package(
    name: "LocusLogicTests",
    platforms: [.macOS("26.0")],
    targets: [
        // One module, as in the Xcode target: the tests use the types directly,
        // without an import.
        .testTarget(
            name: "LocusLogicTests",
            path: ".",
            sources: [
                {listed}
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
""")
    print("Logic tests cover:", *sources, sep="\n  ")

if __name__ == "__main__":
    main()
