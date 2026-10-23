#!/usr/bin/env python3
"""Exercise the production preferences accessor under the real app identity.

This small Foundation-only bundle does not open UI, inspect preference values,
start monitoring, access Keychain, or change the installed app.
"""
import pathlib
import plistlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="watchr-preferences-check-") as temporary:
    directory = pathlib.Path(temporary)
    bundle = directory / "PreferencesProbe.app" / "Contents"
    binary = bundle / "MacOS" / "PreferencesProbe"
    binary.parent.mkdir(parents=True)
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.kylbutlr.statuswatchr",
        "CFBundleExecutable": "PreferencesProbe",
        "CFBundlePackageType": "APPL",
    }))
    main = directory / "main.swift"
    main.write_text('''import Foundation
precondition(Bundle.main.bundleIdentifier == "com.kylbutlr.statuswatchr", "Probe must use the shipped bundle identity")
let preferences = watchrPreferences
precondition(preferences === UserDefaults.standard, "The installed app must use its standard preference domain")
print("PASS: packaged app preferences initialize without a startup trap")
''')
    subprocess.run([
        "swiftc", "-O", "-module-cache-path", str(directory / "module-cache"),
        str(root / "apps/macos/Sources/Services/PublicStorage.swift"), str(main),
        "-o", str(binary),
    ], check=True, timeout=45)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
    if result.returncode:
        print("FAIL: packaged app preferences trapped during initialization", flush=True)
        print(result.stderr[-2000:], flush=True)
        raise SystemExit(1)
    print(result.stdout.strip())
