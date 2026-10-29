#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""The in-place External SSD folder-picker fix (app/Madeira/ExternalGamesPicker.swift).

The fix corrects the iOS folder picker's host identity when BCD is signed with a profile whose App ID
differs from Info.plist's CFBundleIdentifier, so the blue "Open" button returns the real SSD folder in
place (asCopy: false -> OpenInPlace, no -Inbox copy, no copy to the device). It must change nothing for
installs that already work and must never touch Bundle.main.bundleIdentifier (StikJITHelper.swift and
MemoryPool.m read it; changing it would break JIT and the memory host).

Part 1 reads the sources (any host):
  - The decision is gated: a rewrite happens only while the SSD picker session is armed, only on a real
    identity mismatch, and only for the auto-assigned bundle id. Opt-in by use: beginSession is a no-op
    unless needsFix.
  - No global identity change: nothing swizzles NSBundle or bundleIdentifier, and asCopy: true / a forced
    copy mode is never introduced (the in-place path is kept).
  - The settings backend arms the fix around the picker, the startup line carries the match diagnostic
    (booleans only, no App ID value), and the config key is in the generated catalog.
Part 2 (macOS with swift; --require-swift makes it mandatory, as CI does) compiles the pure identity
decision (BCDPickerIdentityDecision) and checks it on worked examples with GENERIC ids (never the owner's).
Run: python3 tests/host/check-external-picker.py [--require-swift]
"""
import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
ap = argparse.ArgumentParser()
ap.add_argument("--require-swift", action="store_true")
args = ap.parse_args()

failed = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failed.append(what)


def read(path):
    return (root / path).read_text(encoding="utf-8")


fix = read("app/Madeira/ExternalGamesPicker.swift")

# ---------------------------------------------------------------- part 1: the sources

check("the fix file carries the BCD SPDX header",
      fix.startswith("// SPDX-License-Identifier: GPL-3.0-only\n// Copyright 2026 thebcd69 (BCD)"))

# Never a global identity change: the owner's hard constraint (JIT / memory host read the bundle id).
# The word "NSBundle" may appear in the explanatory comment; what must be absent is any swizzle of it.
code = "\n".join(line for line in fix.splitlines() if not line.lstrip().startswith("//"))
check("the fix never swizzles NSBundle / Bundle / bundleIdentifier (JIT and the memory host depend on it)",
      "NSBundle" not in code and "Bundle.self" not in code and "method_exchangeImplementations" not in code
      and 'NSSelectorFromString("bundleIdentifier")' not in code and 'forKey: "bundleIdentifier"' not in code)
check("the only swizzled picker machinery is DOCConfiguration.setHostIdentifier: and the picker's viewWillAppear:",
      'NSClassFromString("DOCConfiguration")' in fix
      and 'NSSelectorFromString("setHostIdentifier:")' in fix
      and "#selector(UIViewController.viewWillAppear(_:))" in fix
      and fix.count("method_setImplementation(") == 2
      and fix.count("NSClassFromString(") == 1)   # the only class looked up by string is DOCConfiguration

# The in-place path is kept: the fix never forces a copy.
check("the fix never forces a copy (no asCopy: true, no interactionMode = 0, no copyURLToInbox)",
      "asCopy: true" not in fix and "asCopy:true" not in fix
      and 'setValue(0, forKey: "interactionMode")' not in fix
      and "copyURLToInbox" not in fix)
check("the in-place guarantee is documented (asCopy: false -> OpenInPlace, no -Inbox copy)",
      "asCopy: false" in fix and "-Inbox" in fix and "OpenInPlace" in fix)

# Gating: the setter rewrite is conditioned on an armed session, a real target, and the auto bundle id.
setter = fix[fix.index("private func swizzleSetHostIdentifier()"):fix.index("private func swizzlePickerViewWillAppear()")]
check("the host-identifier rewrite is gated on the armed session and a real mismatch target",
      "if Self.sessionActive, let target" in setter)
check("the host-identifier rewrite only replaces the auto-assigned bundle id (nothing a caller set on purpose)",
      "incoming == nil || incoming == bundleID" in setter)
check("otherwise the original setter runs unchanged",
      setter.count("orig(obj, sel, hostID)") == 1)

# Opt-in by use: beginSession is a no-op unless the install needs the fix.
begin = fix[fix.index("func beginSession()"):fix.index("func endSession()")]
check("beginSession returns at once (no install, no log) unless needsFix", "guard needsFix else { return }" in begin)
check("needsFix is false when the fix is switched off or there is no mismatch/LiveContainer",
      'BCDPickerFixStrategy.current != .off' in fix and "decision.targetHostID != nil || inLiveContainer" in fix)

# The diagnostic is booleans only -- never an App ID value anywhere in the file.
check("the diagnostic suffix is booleans only (appid-match / wildcard / lc), no value",
      'appid-match=\\(decision.matches ? 1 : 0) wildcard=\\(decision.wildcard ? 1 : 0) lc=\\(inLiveContainer ? 1 : 0)' in fix)
# The App ID is read for the decision; the only log line in the file is the one armed line, which carries
# the booleans (diagnosticSuffix), never the target or the entitlement value.
log_block = fix[fix.index("LogStore.shared.log("):][:300] if "LogStore.shared.log(" in fix else ""
check("the fix logs exactly one line, and it carries only the booleans (no App ID value)",
      fix.count("LogStore.shared.log(") == 1 and "diagnosticSuffix" in log_block
      and "targetHostID" not in log_block and "application-identifier" not in log_block)

# The settings backend arms the fix around the picker and surfaces the mismatch help only when it applies.
live = read("app/Madeira/BCDSettingsLive.swift")
check("the settings backend arms the fix when the picker opens", "BCDExternalPickerFix.shared.beginSession()" in live)
check("...and disarms it when the picker closes", "BCDExternalPickerFix.shared.endSession()" in live)
check("...and shows the re-sign guidance only on an install that cannot pick in place",
      "if !pickerAnswered, let help = BCDExternalPickerFix.shared.mismatchHelp" in live)

# The startup signing line carries the match diagnostic.
ent = read("app/Madeira/EntitlementChecker.swift")
check("the startup signing line carries appid-match/wildcard/lc",
      "\\(BCDExternalPickerFix.shared.diagnosticSuffix)" in ent and "[device] signing:" in ent)

# The config key is in the generated catalog with the auto default.
catalog = read("app/Madeira/ConfigCatalog.generated.swift")
check("the external-picker-fix key is in the catalog, default auto",
      'key: "external-picker-fix"' in catalog and 'defaultValue: "auto"' in catalog
      and '("off", "Off (no fix)")' in catalog)

# CI runs this check.
ci = read(".github/workflows/build-ipa.yml")
check("CI runs this check", "run: python3 tests/host/check-external-picker.py --require-swift" in ci)

# ---------------------------------------------------------------- part 2: the decision (macOS + swift)

start = fix.index("struct BCDPickerIdentityDecision")
end = fix.index("/// Which repair the picker applies.")
decision_src = fix[start:end]
check("the pure decision type is sliced out for the harness (no UIKit)", "static func decide(" in decision_src)

harness = "import Foundation\n\n" + decision_src + r'''

func expect(_ got: BCDPickerIdentityDecision, matches: Bool, wildcard: Bool, target: String?, _ name: String) {
    let ok = got.matches == matches && got.wildcard == wildcard && got.targetHostID == target
    print((ok ? "ok   " : "FAIL ") + name + "  got=\(got)")
    if !ok { exit(1) }
}

// A real, specific mismatch (the owner's OTA shape): the bundle id differs from the signed App ID, so the
// picker must be told the real App ID (team prefix stripped). Generic ids only; never the owner's.
expect(BCDPickerIdentityDecision.decide(entitlementAppID: "ABCDE12345.com.example.signer", bundleID: "com.thebcd69.bcd2"),
       matches: false, wildcard: false, target: "com.example.signer", "specific mismatch -> fix with the stripped App ID")

// A working install (SideStore/AltStore/Feather rewrote the bundle id to the App ID): no change.
expect(BCDPickerIdentityDecision.decide(entitlementAppID: "ABCDE12345.com.thebcd69.bcd2", bundleID: "com.thebcd69.bcd2"),
       matches: true, wildcard: false, target: nil, "match -> leave the host id alone")

// A wildcard profile already claims the bundle id's namespace: leave it alone.
expect(BCDPickerIdentityDecision.decide(entitlementAppID: "ABCDE12345.*", bundleID: "com.thebcd69.bcd2"),
       matches: false, wildcard: true, target: nil, "wildcard App ID -> no change")

// Unknown or empty entitlement, or an empty bundle id: never force anything.
expect(BCDPickerIdentityDecision.decide(entitlementAppID: nil, bundleID: "com.thebcd69.bcd2"),
       matches: true, wildcard: false, target: nil, "unreadable entitlement -> no change")
expect(BCDPickerIdentityDecision.decide(entitlementAppID: "", bundleID: "com.thebcd69.bcd2"),
       matches: true, wildcard: false, target: nil, "empty entitlement -> no change")
expect(BCDPickerIdentityDecision.decide(entitlementAppID: "ABCDE12345.com.example.signer", bundleID: ""),
       matches: false, wildcard: false, target: nil, "empty bundle id -> no change")

// A defensive case: an application-identifier with no dot at all is kept whole (real ones always carry
// the "<TeamID>." prefix, so this only guards against a malformed value).
expect(BCDPickerIdentityDecision.decide(entitlementAppID: "wholeid", bundleID: "com.thebcd69.bcd2"),
       matches: false, wildcard: false, target: "wholeid", "no-dot App ID kept whole")

print("External picker decision: all cases passed")
'''

swiftc = shutil.which("xcrun") and shutil.which("swiftc")
if sys.platform != "darwin" or not swiftc:
    check("macOS with swift is here for the decision harness", not args.require_swift)
    print("SKIP: the decision harness needs macOS and Swift.")
else:
    with tempfile.TemporaryDirectory(prefix="bcd-ext-picker-") as directory:
        d = Path(directory)
        (d / "main.swift").write_text(harness, encoding="utf-8")
        compiled = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-o", str(d / "run"), str(d / "main.swift")],
                                  capture_output=True, text=True)
        check("the decision type compiles on the host", compiled.returncode == 0)
        if compiled.returncode != 0:
            print(compiled.stderr[-3000:])
        else:
            ran = subprocess.run([str(d / "run")], capture_output=True, text=True)
            print(ran.stdout.rstrip())
            if ran.stderr.strip():
                print(ran.stderr.rstrip()[-2000:])
            check("the decision cases pass", ran.returncode == 0)

if failed:
    print(f"\n{len(failed)} check(s) failed")
    sys.exit(1)
print("External picker: all checks passed")
