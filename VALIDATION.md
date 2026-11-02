# Validation of AppRestore 0.8.8-public.1

This is a prepared source candidate based on UI 0.8.8 build 38 and Apple engine 0.8.2. It is distinct from the owner's working installation. Validation concerns this source edition; live account/device behavior, clean-machine installation and binary distribution require their own evidence.

| Check | Result and scope |
| --- | --- |
| Canonical source basis | Explicit source/icon/license allowlist fingerprinted before export; must be rechecked before any future upload |
| Native Swift preview | Compiled and locally ad-hoc signed on Apple silicon; macOS 14 target; no installation |
| Python unit suite | 79 tests passed using synthetic/offline fixtures |
| Go helper tests | cmd/apprestore, pkg/appstore, pkg/http passed; internal/netguard compiled but has no test files |
| Native UI capture | Five native views captured with synthetic fixtures; Apple/USB bridge rejection, SQLite reopen with 30 samples, bounded backup receipt and preview backup blocking passed. PNG EXIF contains only pixel dimensions, with no descriptive/device/account/GPS metadata. |
| Full source bundle | Swift UI, Go engine and packaged Python USB built from this public source; deep/strict local signature verification, engine ping and USB startup with EOF passed; Apple runtime preparation was not requested |
| Privacy | Private drive identity/paths excluded; public data namespace separated; native media/metadata and exact source/archive checks completed. Any future change or publication requires a fresh relevant final review. |

Not tested: a clean second Mac, Intel, notarized distribution, fresh Apple login/2FA/download/acquisition, an app installation on a physical iPhone, every USB/backup/export scenario, and the full recipe starting with fresh dependency installation and downloaded Apple runtime. Earlier private-installation reports are not acceptance of this public edition.

The offline screenshots show native current views with an invented device/catalog/history. They must not be described as a live connected-phone session, proof of recovery, a UI mockup or physical-device compatibility acceptance. Both readable native screenshots and their exact source/media hashes must accompany a visual release.

The full build recipe is supplied for review. It requires third-party dependencies and optional explicit runtime preparation. No distribution-ready DMG or official trusted first launch is claimed. A public binary requires separate source freshness, full corresponding-source/license checks, nested-binary/privacy inspection, and exact owner approval.
