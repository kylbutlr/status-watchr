#!/usr/bin/env python3
"""Smoke-test a temporary signed release bundle on the isolated CI runner."""
import pathlib
import subprocess
import sys

bundle = pathlib.Path(sys.argv[1]).resolve()
if pathlib.Path('/Applications') in bundle.parents:
    raise SystemExit('Refusing to test or stop an installed application. Use a temporary extracted bundle.')
binary = bundle / 'Contents/MacOS/StatusWatchr'
if not binary.is_file():
    raise SystemExit('Expected a temporary Status Watchr release bundle.')
process = subprocess.Popen([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    try:
        output, error = process.communicate(timeout=5)
        print(error[-3000:])
        raise SystemExit(f'FAIL: signed app exited during startup ({process.returncode})')
    except subprocess.TimeoutExpired:
        print('PASS: signed packaged app survived startup under its release bundle identity')
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
