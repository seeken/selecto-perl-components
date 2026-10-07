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
           'apt_tempfile_create_failed': 'Could not create temporary file',
           'apt_tempfile_unable': 'Unable to create temporary file',
           'apt_tempfile_couldnt': "Couldn't create temporary file",
           'apt_mkstemp_failed': 'Unable to mkstemp',
           'apt_open_failed': 'Could not open file',
           'apt_failed_to_open': 'Failed to open',
           'apt_write_failed': 'Error writing to output file',
           'apt_failed_to_write': 'Failed to write',
           'apt_write_error': 'Write error',
           'apt_release_info_changed': 'changed its',
           'apt_release_change_required': 'must be accepted explicitly',
           'apt_http_invalid_response': 'Invalid response from server',
           'apt_http_bad_status': 'Bad status line',
           'apt_http_error': 'HTTP error',
           'apt_socket_create_failed': 'Could not create a socket',
           'apt_method_execute_failed': 'Could not execute',
           'apt_nodata': 'NODATA',
           'apt_method_http_died': 'Method http has died unexpectedly',
           'apt_method_https_died': 'Method https has died unexpectedly',
           'apt_subprocess_failed': 'Sub-process',
           'loader_shared_library_error': 'error while loading shared libraries',
           'loader_symbol_error': 'symbol lookup error',
           'process_segfault': 'Segmentation fault',
           'apt_python_binding_error': 'apt_pkg',
           'apt_post_invoke_hook': 'Post-Invoke',
           'python_module_not_found': 'ModuleNotFoundError',
           'apt_could_not_resolve': 'Could not resolve',
           'apt_dns_wicked': 'Something wicked happened resolving',
           'apt_clearsigned_invalid': "Clearsigned file isn't valid",
           'apt_nosplit': 'NOSPLIT',
           'apt_signature_invalid': 'The following signatures were invalid',
           'apt_signature_one_invalid': 'At least one invalid signature',
           'apt_public_key_missing': 'NO_PUBKEY',
           'apt_repository_unsigned': 'is not signed.',
           'apt_release_expired': 'is expired (invalid since',
           'apt_release_not_valid_yet': 'is not valid yet',
           'apt_proxy_invalid_response': 'Invalid response from proxy',
           'apt_proxy_unsupported': 'Unsupported proxy',
           'apt_proxy_bad_header': 'Bad header line',
           'apt_network_unreachable': 'Network is unreachable',
           'apt_no_route': 'No route to host',
           'apt_connection_reset': 'Connection reset by peer',
           'apt_resource_unavailable': 'Resource temporarily unavailable',
           'apt_disk_full': 'No space left on device',
           'apt_read_only_filesystem': 'Read-only file system',
           'apt_lock_failed': 'Could not get lock',
           'apt_empty_reply': 'Empty reply from server',
           'apt_server_read_error': 'Error reading from server',
           'apt_undetermined_error': 'Undetermined Error',
           'apt_certificate_verification_failed': 'Certificate verification failed',
           'apt_certificate_untrusted': 'The certificate is NOT trusted',
           'apt_certificate_issuer_unknown': 'The certificate issuer is unknown',
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
HTTP_CODES = (400, 401, 403, 404, 407, 408, 429, 470, 500, 502, 503, 504)
# These words are diagnostic IDs, never strings copied from installer output.
WORD_IDS = {word: word for word in '''a accepted access acquire address again allocate
allocation already and apt architecture argument authentication available bad be because bind
broken buffer by cannot certificate changed changing checksum cleared clearsigned code
config configuration connect connection could create creating denied device died disk
download downloading empty end error errno execute executing execution expired explicitly
failed failure family fetch file files filesystem following forbidden format from gateway
descriptor directory eacces eaddrnotavail eafnosupport ebadf enomem enospc eperm
eprotonosupport erofs found function get handshake has hash header host http https in index
information initiate inode inodes input install installing insufficient internal invalid invoke
io is issuer its key left length libraries library limit limits line loading lock lookup many
maximum memory message method missing mkstemp module must name network no nodata nosplit not now
of on only open opening operation os out output package passing permission permitted pipe
post process protocol proxy read reading readonly received refused release reply repository
request required reset resolution resolve resolving resource response returned route segmentation
server shared signature signatures signed signing size socket space status subprocess sum
such support supported symbol sync system temporary tempfile terminal the time timed timeout tls to too trusted unable
unauthorized unavailable unexpected unexpectedly unknown unreachable unsupported update
valid value verification verify version warning was wicked with write writing wrong'''.split()}
ERROR_SHAPE_LINES = 16
ERROR_SHAPE_WORDS = 48
ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-_])'
                  r'|\x9b[0-?]*[ -/]*[@-~]')


def normalized(text):
    text = ANSI.sub('', text)
    text = re.sub(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]', ' ', text)
    return re.sub(r'\s+', ' ', text).strip().casefold()


def error_shape(line):
    # Remove locations and opaque values before matching vocabulary or numbers.
    text = re.sub(r'\b[a-z][a-z0-9+.-]*://[^\s<>\"\']+', ' ', line)
    text = re.sub(r'\[[0-9a-f:.]+(?:%[a-z0-9._-]+)?\](?::[0-9]{1,5})?', ' ', text)
    text = re.sub(r'(?<![a-z0-9])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.]*'
                  r'(?:%[a-z0-9._-]+)?(?![a-z0-9])', ' ', text)
    text = re.sub(r'(?<![a-z0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}'
                  r'(?::[0-9]{1,5})?(?![a-z0-9])', ' ', text)
    text = re.sub(r'\b(?:[a-z0-9-]+\.)+[a-z]{2,63}\b', ' ', text)
    text = re.sub(r'\bhttp/[0-9]{1,3}(?:\.[0-9]{1,3})?\b', 'http', text)
    text = re.sub(r'\b[a-z]:[\\/][^\s<>\"\']*|(?<![a-z0-9])/'
                  r'[^\s<>\"\']*|\b[a-z0-9_.-]+(?:[\\/][^\s<>\"\']+)+', ' ', text)
    text = re.sub(r'\b[a-z_][a-z0-9_.-]*\s*=\s*(?:\"[^\"]*\"|\'[^\']*\'|[^\s,;]+)',
                  ' ', text)
    text = re.sub(r'\"[^\"]*\"|\'[^\']*\'', ' ', text)
    def codes(pattern, maximum):
        values = []
        for match in re.finditer(pattern, text):
            code = int(match.group(1) or match.group(2))
            if code <= maximum:
                values.append(code)
                if len(values) == 8:
                    break
        return values
    errno = codes(r'\berrno\s*:?\s*([0-9]{1,4})(?![0-9])|'
                  r'\(([0-9]{1,4})(?![0-9])\s*:\s*[a-z]', 4095)
    http = codes(
        r'\b(?:http|server returned code|status code)\s+([1-5][0-9]{2})(?![0-9])'
        r'|\b([1-5][0-9]{2})(?![0-9])\s+(?:bad request|unauthorized|forbidden|not found|'
        r'too many requests|internal server error|bad gateway|service unavailable|gateway timeout)\b', 599)
    kind = 'warning' if line.startswith('w:') else 'error' if line.startswith('e:') else (
        'index_error' if line.startswith('err:') else 'failed_fetch')
    words = []
    for match in re.finditer(r'\b[a-z]+\b', text):
        word = match.group()
        if word in WORD_IDS:
            words.append(WORD_IDS[word])
            if len(words) == ERROR_SHAPE_WORDS:
                break
    return {'kind': kind, 'word_ids': words,
            'errno_codes': errno, 'http_status_codes': http}


def summarize(output):
    # Every emitted key and string is source-controlled; input contributes counts.
    lines = [normalized(line) for line in output.splitlines()]
    output = '\n'.join(lines)
    markers = {key: min(output.count(normalized(value)), 100000) for key, value in MARKERS.items()}
    hosts = {key: min(len(re.findall(r'(?<![A-Za-z0-9.-])' + re.escape(host) +
                                   r'(?![A-Za-z0-9.-])', output)), 100000)
             for key, host in HOSTS.items()}
    missing = [line for line in lines if any(marker in line for marker in
               ('unable to locate package', 'has no installation candidate', 'is not available'))]
    packages = {package: min(sum(bool(re.search(r'(?<![A-Za-z0-9.+-])' + re.escape(package) +
                                                r'(?![A-Za-z0-9.+-])', line))
                                for line in missing), 100000) for package in PACKAGES}
    http = {str(code): min(len(re.findall(r'(?:HTTP(?:/[0-9.]+)?\s+|server returned code\s+)' +
                                         str(code) + r'\b', output, re.I)), 100000)
            for code in HTTP_CODES}
    for code, phrase in ((400, 'Bad Request'), (470, 'status code 470'), (401, 'Unauthorized'), (403, 'Forbidden'), (404, 'Not Found'),
                         (429, 'Too Many Requests'), (500, 'Internal Server Error'),
                         (502, 'Bad Gateway'), (503, 'Service Unavailable'), (504, 'Gateway Timeout')):
        http[str(code)] = min(http[str(code)] + len(re.findall(r'\b' + str(code) +
                              r'\s+' + re.escape(phrase) + r'\b', output, re.I)), 100000)
    error_lines = [line for line in lines if re.match(r'^(?:w:|e:|err:)', line)
                   or 'failed to fetch' in line]
    error_hosts = {key: min(sum(bool(re.search(r'(?<![A-Za-z0-9.-])' + re.escape(host) +
                                             r'(?![A-Za-z0-9.-])', line))
                               for line in error_lines), 100000)
                   for key, host in HOSTS.items()}
    return {'apt_error_line_count': min(len(error_lines), 100000),
            'apt_error_shapes': [error_shape(line) for line in error_lines[:ERROR_SHAPE_LINES]],
            'apt_error_public_host_ids': error_hosts,
            'marker_counts': markers, 'public_host_ids': hosts,
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
