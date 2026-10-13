#!/usr/bin/env python3
"""Reject native releases that silently omit App Switchr reporting."""
import sys
from pathlib import Path

binary = Path(sys.argv[1]) / 'Contents/MacOS/StatusWatchr'
required = (b'ConnectionRecorder', b'ConnectionTelemetry', b'com.kylbutlr.connections.health-query', b'com.kylbutlr.connections.health-status')
contents = binary.read_bytes()
missing = [marker.decode() for marker in required if marker not in contents]
if missing:
    sys.exit('FAIL: native Connections reporting is missing: ' + ', '.join(missing))
print('PASS: native Connections recorder and live responder are included')
