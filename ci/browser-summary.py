#!/usr/bin/env python3
"""Require complete Playwright coverage and publish only bounded counts."""
import hashlib
import json
import os
from pathlib import Path

root = Path(__file__).resolve().parent.parent
config = json.loads((root / 'ci/beep.json').read_text())
report = Path(os.environ['RUNNER_TEMP']) / 'playwright-results.json'
if not report.is_file() or not 0 < report.stat().st_size <= 20 * 1024 * 1024:
    raise SystemExit('one bounded Playwright report is required')
raw = report.read_bytes()
try:
    stats = json.loads(raw)['stats']
    counts = {name: stats[name] for name in ('expected', 'skipped', 'unexpected', 'flaky')}
except (KeyError, TypeError, json.JSONDecodeError):
    raise SystemExit('malformed Playwright count report') from None
if any(type(value) is not int or value < 0 for value in counts.values()):
    raise SystemExit('invalid Playwright counts')
minimum = config['browser_minimum_tests']
if type(minimum) is not int or minimum <= 0:
    raise SystemExit('a positive browser coverage floor is required')
if counts['skipped'] or counts['unexpected'] or counts['expected'] + counts['flaky'] < minimum:
    raise SystemExit('required browser cases failed, skipped or fell below coverage')
safe = {'counts': counts, 'minimum_tests': minimum,
        'report_sha256': hashlib.sha256(raw).hexdigest(), 'status': 'passed'}
evidence = Path(os.environ['SELECTO_CI_EVIDENCE_DIR'])
evidence.mkdir(parents=True, exist_ok=True)
(evidence / 'browser.json').write_text(json.dumps(safe, indent=2) + '\n')
print(json.dumps(safe))
