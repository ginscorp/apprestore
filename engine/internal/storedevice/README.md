# Isolated Store device authentication

Adapted from MIT-licensed ipatool revision
`8771e57445272459b83b7d423170cc518e419647`, 2026-11-10.
Original source hashes and selected files are in `UPSTREAM.json`.

This separate namespace retains AppRestore's existing package, license and SAP
implementation. It runs the pinned macOS 27.0.1 ARM images inside Unicorn to
complete Store RP/SP provisioning and generate type-2 AMD proof. Guest files,
including the emulated ADI database, exist only in memory; host account stores
are never opened. The proof state is held in the helper's memory store, reused
for 2FA and cleared on logout or process exit. No remote anisette service is used.

Runtime `sap/assets` only reads seven exact-sized, SHA-256-pinned bundled files.
It contains no restore-image downloader or profile generator. Build preparation
is separate: `packaging/prepare_device_assets.py`; all downloaded frameworks
come from Apple's pinned restore image. FairPlayIOKit runs as emulated code;
it is never installed as a host driver. The precomputed Store profile validates
its embedded data hashes before use.

All provisioning HTTP clients use the existing Apple HTTPS guard, no proxy,
no persistent cookies and no redirects. The optional Apple Root CA is pinned
by DER hash and added only to the client trust pool, never to system trust.
Errors expose fixed stages/actions; opaque challenges, proof and Apple bodies
must not be written to diagnostics.
