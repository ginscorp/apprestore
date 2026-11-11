# Validation of AppRestore 0.8.13-public.1

This public adaptation is based on AppRestore 0.8.13 build 43 and engine protocol 0.8.2. It uses separate public storage and is distinct from any private working installation. The exact source and media require a fresh privacy check before every release.

| Check | Result and scope |
| --- | --- |
| Swift UI | Type checking passed on an Apple-silicon Mac; this alone is not a full bundle test. |
| Go engine | Tests for cmd/apprestore, pkg/appstore and pkg/http passed with a synthetic profile; a generated synthetic profile loaded successfully. |
| Pinned upstream profile | The exact public upstream file was verified by size and SHA-256. A private test engine built with it and returned a successful ping without an Apple account. The profile is not part of this repository. |
| Build safeguards | Synthetic tests checked the allowlisted build copy, checksum rejection, link rejection and private-package exclusion. |
| Public data root | Synthetic tests reopened 30 history records and passed SQLite integrity checks with both an explicit canonical temporary path and the default preview path. Symlink roots, symlink ancestors and parent traversal were rejected without writing to their targets. |
| Modern runtime preparation | Synthetic tests checked host and byte restrictions, non-overwrite behavior and rejection of partially existing assets. A fresh end-to-end preparation remains unverified. |
| Native demo | Five native synthetic-preview frames were recaptured from this UI; the existing previously approved frames are retained where their image pixels match. |
| Full bundle | A local Apple-silicon full-bundle build succeeded without preparing Apple runtime. The public data-root safety adjustment was compiled and tested separately; live Apple authentication is not demonstrated by a build or ping. |
| Privacy | No publication is permitted without a separate final review of the exact source, media and metadata. |

The previous 0.8.8 public preparation had 79 passing Python unit tests; that historical result is not a fresh result for this revision. Not tested for this revision: clean second Mac, Intel, notarized distribution, fresh Apple login/2FA/download, physical-iPhone installation, all USB/backup/export scenarios, and a fresh full runtime download. Earlier private-installation reports are not acceptance of this public edition.

Screenshots must show the current native public preview with synthetic device, catalog and history data. They are not proof of a connected iPhone, account access, or recovery. A future binary release requires separate license, source, nested-binary and privacy checks.
