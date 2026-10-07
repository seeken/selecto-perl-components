#!/usr/bin/env python3
"""Run the pinned browser installer and expose only finite diagnostic IDs."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

COMMAND = ['npx', 'playwright', 'install', '--with-deps', 'chromium']
TIMEOUT = 900
LIMIT = 20 * 1024 * 1024
# Public installer origins and Debian/Ubuntu Chromium packages from the locked
# Playwright 1.62.1 release. Output never includes arbitrary hosts or packages.
HOSTS = {'playwright_cdn': 'cdn.playwright.dev',
         'playwright_microsoft': 'playwright.download.prss.microsoft.com',
         'microsoft_download': 'download.prss.microsoft.com',
         'playwright_azure': 'playwright.azureedge.net',
         'chrome_storage': 'storage.googleapis.com',
         'ubuntu_archive': 'archive.ubuntu.com',
         'ubuntu_security': 'security.ubuntu.com',
         'ubuntu_ports': 'ports.ubuntu.com',
         'debian_archive': 'deb.debian.org',
         'debian_security': 'security.debian.org'}
PACKAGES = '''xvfb fonts-noto-color-emoji fonts-unifont libfontconfig1 libfreetype6
xfonts-cyrillic xfonts-scalable fonts-liberation fonts-ipafont-gothic
fonts-wqy-zenhei fonts-tlwg-loma-otf fonts-freefont-ttf libasound2 libasound2t64
libatk-bridge2.0-0 libatk-bridge2.0-0t64 libatk1.0-0 libatk1.0-0t64
libatspi2.0-0 libatspi2.0-0t64 libcairo2 libcups2 libcups2t64 libdbus-1-3
libdrm2 libgbm1 libglib2.0-0 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0
libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0
libxrandr2'''.split()
MARKERS = {'apt_started': 'Installing dependencies...',
           'apt_fetch_failed': 'Failed to fetch',
           'apt_resolution_failed': 'Temporary failure resolving',
           'apt_connect_failed': 'Could not connect',
           'apt_connection_failed': 'Connection failed',
           'apt_connection_refused': 'Connection refused',
           'apt_connection_timeout': 'Connection timed out',
           'apt_hash_mismatch': 'Hash Sum mismatch',
           'apt_unexpected_size': 'File has unexpected size',
           'apt_release_missing': 'does not have a Release file',
           'apt_index_failed': 'Some index files failed to download',
           'apt_tls_handshake_failed': 'Could not handshake',
           'apt_package_missing': 'Unable to locate package',
           'apt_no_candidate': 'has no installation candidate',
           'permission_denied': 'Permission denied',
           'sudo_password_required': 'a password is required',
           'sudo_terminal_required': 'a terminal is required',
           'installer_process_failed': 'Installation process exited with code:',
           'browser_download_started': 'Downloading Chrome',
           'chromium_download_started': 'Downloading Chromium',
           'browser_download_failed': 'Failed to download',
           'dns_not_found': 'ENOTFOUND', 'dns_temporary': 'EAI_AGAIN',
           'connection_refused': 'ECONNREFUSED', 'connection_reset': 'ECONNRESET',
           'connection_timeout': 'ETIMEDOUT', 'certificate_expired': 'CERT_HAS_EXPIRED',
           'certificate_untrusted': 'UNABLE_TO_VERIFY_LEAF_SIGNATURE'}
HTTP_CODES = (401, 403, 404, 407, 408, 429, 500, 502, 503, 504)


def summarize(output):
    # Every emitted key and string is source-controlled; input contributes counts.
    markers = {key: min(output.count(value), 100000) for key, value in MARKERS.items()}
    hosts = {key: min(len(re.findall(r'(?<![A-Za-z0-9.-])' + re.escape(host) +
                                   r'(?![A-Za-z0-9.-])', output)), 100000)
             for key, host in HOSTS.items()}
    missing = [line for line in output.splitlines() if any(marker in line for marker in
               ('Unable to locate package', 'has no installation candidate', 'is not available'))]
    packages = {package: min(sum(bool(re.search(r'(?<![A-Za-z0-9.+-])' + re.escape(package) +
                                                r'(?![A-Za-z0-9.+-])', line))
                                for line in missing), 100000) for package in PACKAGES}
    http = {str(code): min(len(re.findall(r'(?:HTTP(?:/[0-9.]+)?\s+|server returned code\s+)' +
                                         str(code) + r'\b', output, re.I)), 100000)
            for code in HTTP_CODES}
    for code, phrase in ((401, 'Unauthorized'), (403, 'Forbidden'), (404, 'Not Found'),
                         (429, 'Too Many Requests'), (500, 'Internal Server Error'),
                         (502, 'Bad Gateway'), (503, 'Service Unavailable'), (504, 'Gateway Timeout')):
        http[str(code)] = min(http[str(code)] + len(re.findall(r'\b' + str(code) +
                              r'\s+' + re.escape(phrase) + r'\b', output, re.I)), 100000)
    return {'marker_counts': markers, 'public_host_ids': hosts,
            'missing_package_counts': packages, 'http_status_counts': http}


def run(command, timeout=TIMEOUT, limit=LIMIT):
    start = time.monotonic()
    status = 'passed'
    with tempfile.TemporaryFile() as log:
        proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        while proc.poll() is None:
            if time.monotonic() - start > timeout or os.fstat(log.fileno()).st_size > limit:
                status = 'timeout' if time.monotonic() - start > timeout else 'output_limit'
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                break
            time.sleep(0.1)
        code = proc.returncode
        if os.fstat(log.fileno()).st_size > limit:
            status = 'output_limit'
        log.seek(0)
        output = log.read(limit).decode('utf-8', errors='replace')
    if status == 'passed' and code != 0:
        status = 'command_failed'
    return {'schema': 'selecto.playwright.install.v1', 'status': status, 'exit_code': code,
            'elapsed_seconds': round(time.monotonic() - start, 3),
            'output_bytes_examined': len(output.encode('utf-8')),
            **summarize(output)}


def main():
    evidence = Path(os.environ['SELECTO_CI_EVIDENCE_DIR']).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    version = json.loads(Path('package-lock.json').read_text())['packages']['node_modules/playwright-core']['version']
    if version != '1.62.1':
        raise SystemExit('browser_installer_diagnostic_version_changed')
    report = run(COMMAND)
    report['playwright_version'] = version
    path = evidence / 'browser-install-detail.json'
    path.write_text(json.dumps(report, indent=2) + '\n')
    path.chmod(0o600)
    print(json.dumps(report))
    return 0 if report['status'] == 'passed' else (report['exit_code'] if report['exit_code'] > 0 else 1)


if __name__ == '__main__':
    raise SystemExit(main())
