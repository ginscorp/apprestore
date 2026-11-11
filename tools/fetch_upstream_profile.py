"""Fetch a pinned public upstream build dependency outside the repository."""
from pathlib import Path
import argparse
import hashlib
import os
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
URL = ('https://raw.githubusercontent.com/majd/ipatool/'
       '8771e57445272459b83b7d423170cc518e419647/internal/store/profile/data_generated.go')
SIZE = 6708815
SHA256 = '0a77c1b8c42f4157befac81779f2233d308b3d67d057d7785f8398021f38d9fc'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Redirects are not allowed')


def fetch_bytes(opener, url=URL, size=SIZE, sha256=SHA256):
    request = urllib.request.Request(url, headers={'User-Agent': 'AppRestore-public-build'})
    with opener.open(request, timeout=90) as response:
        if response.status != 200:
            raise ValueError('Unexpected upstream response')
        data = response.read(size + 1)
    if len(data) != size or hashlib.sha256(data).hexdigest() != sha256:
        raise ValueError('Upstream profile length or checksum mismatch')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True,
                        help='New file outside the repository; never commit this dependency')
    args = parser.parse_args()
    output = args.output.expanduser().absolute()
    if output.exists() or output.is_symlink() or output.resolve().is_relative_to(ROOT):
        parser.error('Choose a new output file outside the repository')
    if not output.parent.is_dir():
        parser.error('The output parent directory must already exist')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    data = fetch_bytes(opener)
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(fd, 'wb') as file:
        file.write(data)
    if hashlib.sha256(output.read_bytes()).hexdigest() != SHA256:
        raise ValueError('Saved profile verification failed')
    print('Pinned upstream dependency saved outside the source tree. Do not commit or publish it.')


if __name__ == '__main__':
    main()
