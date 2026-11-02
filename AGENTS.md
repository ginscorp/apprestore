# AppRestore contributor and agent guide

Read both README versions and VALIDATION.md before changing behavior. Swift/AppKit UI is in app/, Go engine source is in engine/, Python USB source is in usb/, and build/capture helpers are in tools/ and demo/. Keep the UI, engine and public-edition version meanings distinct.

Start with the offline preview. It must reject Apple and USB bridge calls and use synthetic data. Do not access real accounts, Keychain entries, connected devices, pairing records, private databases or Apple runtime downloads merely to inspect or capture the UI. Treat installation, account actions, imports/exports and device changes as separate authorized operations. Never bake credentials, account profiles, real device records or private endpoints into code, images, archives or metadata.

Keep public storage separate from other installations. Preserve bounds, symlink checks, explicit backup destinations and copy/SHA receipts. Add no automatic deletion. Change both README languages together and show only actual current anonymized UI with meaningful captions/alt. Retain upstream license notices; do not relabel the entire product MIT.

For authorized offline checks, run Python unit tests with dependencies installed, and the Go helper/appstore/HTTP tests. Use tools/build.py preview with a new explicit output directory. Native capture is an offscreen synthetic fixture, not proof of a real phone session. Build outputs and dependency caches belong outside source. Do not install, sign with a personal identity, publish, notarize or modify system security merely because a build succeeded.


## Release coordination

After a meaningful, ready change, record the local version, user-visible changes, checks and differences from the last verified published revision, even if the version number did not change. Propose a concrete GitHub update to the maintainer. Agree the release-review cadence per product: a number of ready versions and, when useful, a maximum wait. Do not count individual commits or draft builds as ready versions. Until a cadence is agreed, raise each meaningful ready change for review; discuss security fixes, data-loss risks and a broken primary launch promptly.

Keep a concise pending-change handoff and report whether publication is current, needs review, or has only been prepared. Do not claim the remote state is current without verification. Refresh both README languages, examples and affected real anonymized screenshots when behavior changes. A cadence agreement does not authorize uploads: prepare and verify the exact scope, obtain applicable maintainer authorization, and perform a fresh source-revision and final sensitive-data/metadata review before publishing. Preserve the operator's local Git restrictions. After an authorized update, verify the published revision and close only the changes actually included.
