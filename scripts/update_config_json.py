#!/usr/bin/env python3
"""Shared update metadata publisher. Credentials come only from the environment."""
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import urlsplit, urlunsplit
from urllib.request import Request, urlopen


def normalize_signatures(value):
    signatures = sorted({s.strip().lower() for s in value.split(',') if s.strip()})
    if any(re.fullmatch(r'[0-9a-f]{40}', s) is None for s in signatures):
        raise ValueError('Expected SHA-1 signing certificate fingerprints')
    return signatures


def get_apk_signature(apk):
    candidates = []
    for variable in ['ANDROID_HOME', 'ANDROID_SDK_ROOT']:
        sdk = os.environ.get(variable)
        if sdk:
            candidates.extend(sorted(Path(sdk).glob('build-tools/*/apksigner'), reverse=True))
    if shutil.which('apksigner'):
        candidates.append(Path(shutil.which('apksigner')))
    if candidates:
        command = [str(candidates[0])]
    else:
        jar = Path(__file__).resolve().parents[2] / 'signer/apksigner.jar'
        if not jar.is_file():
            raise ValueError('Install Android SDK build-tools to verify APK signing')
        command = ['java', '-jar', str(jar)]
    result = subprocess.run(command + ['verify', '--print-certs', str(apk)],
                            check=True, capture_output=True, text=True)
    fingerprints = re.findall(r'certificate SHA-1 digest: ([a-fA-F0-9]+)', result.stdout)
    if not fingerprints:
        raise ValueError('No verified APK signing certificates found')
    return normalize_signatures(','.join(fingerprints))


def metadata(platform, variant, version, build, download_url, signatures=(), file_size=0):
    if platform.startswith('android') and not signatures:
        raise ValueError('Android metadata requires verified signing certificates')
    key = variant + ('-' + '-'.join(signatures) if signatures else '')
    return {'platform': platform, 'identifier': key, 'data': {
        'version': version, 'build': int(build), 'signatures': list(signatures),
        'url': f'https://github.com/iebb/NekokoLPA2/releases/tag/v{version}%2B{build}',
        'download_url': download_url, 'changelog': 'Update available.',
        'published_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'file_size': file_size,
    }}


def publish(payload):
    endpoint = os.environ.get('UPDATE_WORKER_URL', '')
    key = os.environ.get('UPDATE_WORKER_KEY', '')
    if not endpoint or not key:
        raise ValueError('UPDATE_WORKER_URL and UPDATE_WORKER_KEY must be configured')
    parsed = urlsplit(endpoint)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError('Expected an HTTPS update-worker endpoint')
    # Authentication belongs in the header, never in logged URLs/query strings.
    endpoint = urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip('/') or '/nlpa2', '', ''))
    request = Request(endpoint, data=json.dumps(payload).encode(), method='POST', headers={
        'Content-Type': 'application/json', 'X-Access-Key': key,
        'User-Agent': 'NekokoLPA/release-publisher',
    })
    try:
        with urlopen(request, timeout=30) as response:
            result = json.load(response)
        if result.get('success') is not True:
            raise ValueError('Update worker did not acknowledge the write')
    except Exception:
        # Do not include access-bearing URLs or server responses in CI logs.
        raise RuntimeError('Update worker rejected or failed the metadata write') from None
    print(f"Published {payload['platform']}/{payload['identifier']} build {payload['data']['build']}")


def main():
    if len(sys.argv) < 7:
        raise ValueError('Usage: update_config_json.py none platform variant version build download_url [APK/file/fingerprints]')
    _, platform, variant, version, build, download_url, *references = sys.argv[1:]
    reference = references[0] if references else ''
    path = Path(reference) if reference else None
    signatures = []
    size = path.stat().st_size if path and path.is_file() else 0
    if platform.startswith('android'):
        signatures = get_apk_signature(path) if path and path.is_file() else normalize_signatures(reference)
    publish(metadata(platform, variant or 'std', version, build, download_url, signatures, size))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'Update publication failed: {error}', file=sys.stderr)
        sys.exit(1)
