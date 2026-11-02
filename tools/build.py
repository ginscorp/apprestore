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
VERSION = '0.8.8'


def copied_file(source, target):
    data = source.read_bytes()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    assert target.read_bytes() == data


def run(command, env):
    subprocess.run([str(x) for x in command], check=True, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['preview', 'capture', 'full'])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--go', default='go')
    parser.add_argument('--python', default='python3')
    parser.add_argument('--module-cache', type=Path)
    parser.add_argument('--swift-cache', type=Path)
    parser.add_argument('--prepare-runtime', action='store_true',
                        help='Explicitly fetch pinned public runtime assets for Apple operations')
    args = parser.parse_args()
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
        go_env = dict(env, GOTOOLCHAIN='local', GOCACHE=str(cache / 'go-build'),
                      GOMODCACHE=str(args.module_cache.resolve() if args.module_cache else cache / 'go-modules'),
                      GOENV='off', GOTELEMETRY='off', GOPROXY='https://proxy.golang.org', GOSUMDB='sum.golang.org')
        subprocess.run([args.go, 'build', '-mod=readonly', '-trimpath', '-buildvcs=false', '-o',
                        str(resources / 'apprestore-engine'), './cmd/apprestore'],
                       cwd=ROOT / 'engine', env=go_env, check=True)
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
    elif args.prepare_runtime:
        parser.error('--prepare-runtime is supported only with full')
    info = {'CFBundleName': 'AppRestore Preview' if args.mode != 'full' else 'AppRestore',
            'CFBundleDisplayName': 'AppRestore Preview' if args.mode != 'full' else 'AppRestore',
            'CFBundleIdentifier': 'org.example.apprestore.public' + ('.capture' if args.mode == 'capture' else ''),
            'CFBundleExecutable': 'AppRestore', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': VERSION, 'CFBundleVersion': '38',
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
