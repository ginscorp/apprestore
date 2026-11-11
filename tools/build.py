"""Build into a new explicit output directory; never installs or replaces an app."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.8.13'
UPSTREAM_PROFILE_SIZE = 6708815
UPSTREAM_PROFILE_SHA256 = '0a77c1b8c42f4157befac81779f2233d308b3d67d057d7785f8398021f38d9fc'


def copied_file(source, target):
    data = source.read_bytes()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    if target.read_bytes() != data:
        raise ValueError('Copied file verification failed')


def run(command, env):
    subprocess.run([str(x) for x in command], check=True, env=env)


def prepare_engine(source, destination, profile, expected_size=UPSTREAM_PROFILE_SIZE,
                   expected_sha256=UPSTREAM_PROFILE_SHA256):
    """Create a build-only engine copy; the generated upstream profile stays outside the repository."""
    if profile.is_symlink() or not profile.is_file() or profile.stat().st_size != expected_size:
        raise ValueError('Expected the exact pinned upstream profile file')
    data = profile.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected_sha256:
        raise ValueError('Upstream profile checksum mismatch')
    if destination.exists() or destination.is_symlink():
        raise ValueError('Engine build directory already exists')
    destination.mkdir(parents=True)
    count = 0
    for item in sorted(source.rglob('*')):
        if item.is_symlink():
            raise ValueError('Engine source contains a symbolic link')
        if not item.is_file():
            continue
        relative = item.relative_to(source)
        if '.git' in relative.parts or item.name in {'.env', '.DS_Store', 'data_generated.go'}:
            continue
        if item.suffix != '.go' and str(relative) not in {'go.mod', 'go.sum'}:
            continue
        copied_file(item, destination / relative)
        count += 1
    if not count or not (destination / 'go.mod').is_file():
        raise ValueError('Engine source is incomplete')
    target = destination / 'internal/storedevice/store/profile/data_generated.go'
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open('xb') as output:
        output.write(data)
    if hashlib.sha256(target.read_bytes()).hexdigest() != expected_sha256:
        raise ValueError('Build profile verification failed')


def prepare_modern_runtime(go, output, go_env, runtime_env):
    """Build and explicitly run the guarded public Apple asset preparer."""
    helper = output / 'work/prepare-modern-assets'
    subprocess.run([str(go), 'build', '-mod=readonly', '-trimpath', '-buildvcs=false',
                    '-o', str(helper), './cmd/prepare'],
                   cwd=ROOT / 'tools/device-assets', env=go_env, check=True)
    assets_env = dict(runtime_env, APPRESTORE_MODERN_ASSETS=str(
        Path(runtime_env['APPRESTORE_RUNTIME']) / 'ipatool/sap'))
    run([helper], assets_env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['preview', 'capture', 'full'])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--go', default='go')
    parser.add_argument('--python', default='python3')
    parser.add_argument('--module-cache', type=Path)
    parser.add_argument('--swift-cache', type=Path)
    parser.add_argument('--profile-file', type=Path,
                        help='Pinned public upstream profile, kept outside the repository')
    parser.add_argument('--prepare-runtime', action='store_true',
                        help='Explicitly fetch pinned public runtime assets for Apple operations')
    args = parser.parse_args()
    if args.mode == 'full' and args.profile_file is None:
        parser.error('Full build requires --profile-file with the pinned upstream profile')
    if args.mode != 'full' and args.profile_file is not None:
        parser.error('--profile-file applies only to a full build')
    if args.profile_file is not None and args.profile_file.expanduser().resolve().is_relative_to(ROOT):
        parser.error('Keep the upstream profile outside the source tree')
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('This build recipe is currently tested on Apple silicon macOS only')
    output = args.output.expanduser().resolve()
    if output.exists() or output == ROOT or ROOT in output.parents:
        parser.error('Choose a new output directory outside the source tree')
    output.mkdir(parents=True)
    cache = output / 'cache'
    cache.mkdir()
    temporary = output / 'tmp'
    temporary.mkdir()
    env = dict(os.environ, TMPDIR=str(temporary), PYTHONDONTWRITEBYTECODE='1',
               PYTHONNOUSERSITE='1', PYINSTALLER_CONFIG_DIR=str(cache / 'pyinstaller'))
    app = output / ('AppRestore Preview.app' if args.mode != 'full' else 'AppRestore.app')
    resources = app / 'Contents/Resources'
    resources.mkdir(parents=True)
    binary = app / 'Contents/MacOS/AppRestore'
    binary.parent.mkdir()
    for language in ['en', 'ru']:
        copied_file(ROOT / f'assets/localization/{language}.lproj/Localizable.strings',
                    resources / f'{language}.lproj/Localizable.strings')
    copied_file(ROOT / 'assets/AppRestore.icns', resources / 'AppRestore.icns')
    copied_file(ROOT / 'demo/catalog.json', resources / 'Demo/catalog.json')
    for name in ['Citrus-Battery-GPL-3.0.txt', 'Stats-MIT.txt',
                 'pymobiledevice3-GPL-3.0.txt', 'pyiosbackup-GPL-3.0.txt']:
        copied_file(ROOT / 'assets/third-party' / name, resources / 'Licenses' / name)
    copied_file(ROOT / 'engine/LICENSE', resources / 'Licenses/ipatool-MIT.txt')
    if (ROOT / 'LICENSE').exists():
        copied_file(ROOT / 'LICENSE', resources / 'Licenses/AppRestore-LICENSE.txt')
    sources = sorted((ROOT / 'app').glob('*.swift'))
    command = ['/usr/bin/swiftc', '-swift-version', '5', '-target', 'arm64-apple-macos14.0',
               '-module-cache-path', args.swift_cache.resolve() if args.swift_cache else cache / 'swift-modules', '-parse-as-library', '-O',
               '-import-objc-header', ROOT / 'app/NativeSMART.h']
    if args.mode == 'capture':
        command += ['-D', 'APPRESTORE_LAYOUT_TEST']
        sources.append(ROOT / 'demo/ScreenshotHarness.swift')
    command += sources + ['-o', binary, '-lsqlite3']
    for framework in ['SwiftUI', 'AppKit', 'IOKit', 'Security', 'LocalAuthentication',
                      'CoreText', 'ImageIO', 'ImageCaptureCore', 'PDFKit', 'CoreGraphics']:
        command += ['-framework', framework]
    run(command, env)
    if args.mode == 'full':
        engine_build = output / 'work/engine'
        prepare_engine(ROOT / 'engine', engine_build, args.profile_file.expanduser().absolute())
        go_env = dict(env, GOTOOLCHAIN='local', GOCACHE=str(cache / 'go-build'),
                      GOMODCACHE=str(args.module_cache.resolve() if args.module_cache else cache / 'go-modules'),
                      GOENV='off', GOTELEMETRY='off', GOPROXY='https://proxy.golang.org', GOSUMDB='sum.golang.org')
        subprocess.run([args.go, 'build', '-mod=readonly', '-trimpath', '-buildvcs=false', '-o',
                        str(resources / 'apprestore-engine'), './cmd/apprestore'],
                       cwd=engine_build, env=go_env, check=True)
        run([args.python, '-m', 'PyInstaller', '--noconfirm', '--onedir', '--name',
             'apprestore-usb', '--distpath', output / 'helper-dist', '--workpath',
             output / 'helper-work', '--specpath', output / 'helper-spec', '--paths',
             ROOT / 'usb', ROOT / 'usb/bridge.py'], env)
        source = output / 'helper-dist/apprestore-usb'
        target = resources / 'USB'
        shutil.copytree(source, target, symlinks=True)
        before = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in source.rglob('*') if p.is_file() and not p.is_symlink()}
        after = {str(p.relative_to(target)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in target.rglob('*') if p.is_file() and not p.is_symlink()}
        assert before and before == after
        if args.prepare_runtime:
            runtime_env = dict(env, APPRESTORE_RUNTIME=str(resources / 'Runtime'))
            run([resources / 'apprestore-engine', '--prepare'], runtime_env)
            prepare_modern_runtime(args.go, output, go_env, runtime_env)
    elif args.prepare_runtime:
        parser.error('--prepare-runtime is supported only with full')
    info = {'CFBundleName': 'AppRestore Preview' if args.mode != 'full' else 'AppRestore',
            'CFBundleDisplayName': 'AppRestore Preview' if args.mode != 'full' else 'AppRestore',
            'CFBundleIdentifier': 'org.example.apprestore.public' + ('.capture' if args.mode == 'capture' else ''),
            'CFBundleExecutable': 'AppRestore', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': VERSION, 'CFBundleVersion': '43',
            'CFBundleIconFile': 'AppRestore.icns', 'LSMinimumSystemVersion': '14.0',
            'NSHighResolutionCapable': True, 'NSQuitAlwaysKeepsWindows': False,
            'CFBundleDevelopmentRegion': 'ru', 'CFBundleLocalizations': ['ru', 'en'],
            'AppRestorePreview': args.mode != 'full'}
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    run(['/usr/bin/codesign', '--force', '--sign', '-', app], env)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app], env)
    receipt = {'app': str(app), 'mode': args.mode, 'version': VERSION,
               'installed': False, 'ad_hoc_signed': True, 'notarized': False,
               'apple_runtime_prepared': args.prepare_runtime, 'output_root': str(output)}
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
