from pathlib import Path
import hashlib
import importlib.util
import tempfile

here = Path(__file__).parent
def load(name):
    spec = importlib.util.spec_from_file_location(name, here / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

build = load('build')
fetch = load('fetch_upstream_profile')
root = Path(tempfile.mkdtemp(prefix='AppRestore-build-test-', dir='/private/tmp'))
source = root / 'engine-source'
source.mkdir()
(source / 'go.mod').write_text('module example.invalid/synthetic\n')
(source / 'main.go').write_text('package example\n')
(source / 'private.ipa').write_bytes(b'SYNTHETIC-NOT-AN-IPA')
profile = root / 'profile'
profile.write_bytes(b'SYNTHETIC PROFILE')
digest = hashlib.sha256(profile.read_bytes()).hexdigest()
output = root / 'engine-build'
build.prepare_engine(source, output, profile, len(profile.read_bytes()), digest)
assert (output / 'main.go').exists() and not (output / 'private.ipa').exists()
assert (output / 'internal/storedevice/store/profile/data_generated.go').read_bytes() == profile.read_bytes()
try:
    build.prepare_engine(source, root / 'bad-hash', profile, len(profile.read_bytes()), '0' * 64)
    raise AssertionError('wrong hash accepted')
except ValueError:
    pass
assert not (root / 'bad-hash').exists()
link = root / 'profile-link'
link.symlink_to(profile)
try:
    build.prepare_engine(source, root / 'link-build', link, len(profile.read_bytes()), digest)
    raise AssertionError('linked profile accepted')
except ValueError:
    pass
assert not (root / 'link-build').exists()

calls = []
real_run = build.subprocess.run
def fake_run(command, **kwargs):
    calls.append((command, kwargs))
try:
    build.subprocess.run = fake_run
    build.prepare_modern_runtime('synthetic-go', root / 'build-output',
                                 {'GOPROXY': 'off'}, {'APPRESTORE_RUNTIME': str(root / 'runtime')})
finally:
    build.subprocess.run = real_run
assert len(calls) == 2 and calls[0][0][0] == 'synthetic-go'
assert calls[1][1]['env']['APPRESTORE_MODERN_ASSETS'] == str(root / 'runtime/ipatool/sap')

class FakeResponse:
    status = 200
    def __enter__(self): return self
    def __exit__(self, *args): return False
    def read(self, limit): return b'SYNTHETIC'[:limit]
class FakeOpener:
    def open(self, request, timeout):
        assert request.full_url == 'https://example.invalid/synthetic' and timeout == 90
        return FakeResponse()

expected = hashlib.sha256(b'SYNTHETIC').hexdigest()
assert fetch.fetch_bytes(FakeOpener(), 'https://example.invalid/synthetic', 9, expected) == b'SYNTHETIC'
try:
    fetch.fetch_bytes(FakeOpener(), 'https://example.invalid/synthetic', 9, '0' * 64)
    raise AssertionError('wrong download hash accepted')
except ValueError:
    pass
print('PASS: filtered engine copy, private package exclusion, pinned checksum and synthetic download')
print('Test files retained:', root)
