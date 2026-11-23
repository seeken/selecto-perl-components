#!/usr/bin/env python3
"""Require complete Playwright coverage and publish only bounded counts."""
import hashlib
import json
import os
import re
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


def printable(text):
    text = re.sub(r'\x1b\[[0-9;]*m', '', text)
    return ''.join(ch if ' ' <= ch <= '~' else ' ' for ch in text)


def assertion(spec):
    """The first assertion message of a failed spec, bounded and printable.

    Playwright assertion messages hold the expected and received values of
    the synthetic fixtures; stage output and the environment are never read.
    """
    for test in spec.get('tests', []):
        for result in test.get('results', []):
            for error in result.get('errors', []) or [result.get('error') or {}]:
                message = error.get('message') if isinstance(error, dict) else None
                if isinstance(message, str) and message:
                    return printable(message)[:400]
    return ''


def failed_titles(suites, limit=20):
    """Failed or skipped specs with their repo-authored titles."""
    found = []
    def walk(suite):
        for spec in suite.get('specs', []):
            if not spec.get('ok', True) and len(found) < limit:
                title = '{}:{} {}'.format(spec.get('file', ''), spec.get('line', ''), spec.get('title', ''))
                found.append({'spec': printable(title)[:200], 'assertion': assertion(spec)})
        for child in suite.get('suites', []):
            walk(child)
    for suite in suites if isinstance(suites, list) else []:
        if isinstance(suite, dict):
            walk(suite)
    return found


if counts['skipped'] or counts['unexpected'] or counts['expected'] + counts['flaky'] < minimum:
    failed = {'counts': counts, 'minimum_tests': minimum, 'status': 'failed',
              'failed_specs': failed_titles(json.loads(raw).get('suites'))}
    evidence = Path(os.environ['SELECTO_CI_EVIDENCE_DIR'])
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'browser-playwright.json').write_text(json.dumps(failed, indent=2) + '\n')
    print(json.dumps(failed))
    raise SystemExit('required browser cases failed, skipped or fell below coverage')
safe = {'counts': counts, 'minimum_tests': minimum,
        'report_sha256': hashlib.sha256(raw).hexdigest(), 'status': 'passed'}
evidence = Path(os.environ['SELECTO_CI_EVIDENCE_DIR'])
evidence.mkdir(parents=True, exist_ok=True)
(evidence / 'browser-playwright.json').write_text(json.dumps(safe, indent=2) + '\n')
print(json.dumps(safe))
