# Origin and component licenses

The AppRestore native workspace and its adaptations combine original code with explicitly credited components. The combined AppRestore distribution is licensed GPL-3.0-only under the root LICENSE. The existing component notices remain in force; this does not replace the MIT terms of the Go engine and other permissive components.

| Component | Role | Recorded license and source |
| --- | --- | --- |
| ipatool | Modified Go Apple engine | MIT; engine/LICENSE; https://github.com/majd/ipatool |
| ipatool Store device adaptation | Isolated Store authentication code | MIT upstream, revision 8771e57445272459b83b7d423170cc518e419647; engine/LICENSE; https://github.com/majd/ipatool |
| pymobiledevice3 11.41.2 | Python USB services | GPL v3; assets/third-party/pymobiledevice3-GPL-3.0.txt; https://github.com/doronz88/pymobiledevice3 |
| pyiosbackup 0.2.4 | Selected backup-reading/crypto integration | GPL v3; assets/third-party/pyiosbackup-GPL-3.0.txt; https://pypi.org/project/pyiosbackup/0.2.4/ |
| citrus-battery format research | coconutBattery interoperability and battery-origin research | Recorded GPL v3; assets/third-party/Citrus-Battery-GPL-3.0.txt; recorded revision c7cd8a122f23c7be6fff2c09e97cdbda8648256c; https://github.com/citrus-apps/citrus-battery |
| Stats | AppleSmartBatteryPack/read-only SMC references | MIT; assets/third-party/Stats-MIT.txt; recorded revision 032f4a5e4cb9c11bc537c70a9487dfd904f2011d; https://github.com/exelban/stats |

The public citrus-battery license at the recorded revision was verified through the official GitHub API during preparation. Its complete GPL v3 license text matches the retained local notice, apart from surrounding whitespace. Upstream availability, exact revision and license text were verified independently.

Apple frameworks are system dependencies. Proprietary Apple runtime assets, the coconutBattery binary/key and personalized IPA/SINF files are not redistributed in this source export. Optional runtime preparation obtains pinned components from their original distribution sources; a future binary release needs its own distribution-rights and corresponding-source review.

The full build also needs a pinned upstream generated Store profile containing Apple-derived materials. It is fetched by an explicit local step and kept outside this repository. The upstream project's MIT license does not itself establish redistribution rights for Apple-derived materials; local use and any future binary distribution require their own terms review.

The Python environment is pinned in requirements-lock.txt; Go dependencies are pinned by engine/go.mod and engine/go.sum. Their individual licenses continue to apply. Runtime packages such as cryptography, Python, PyInstaller and Unicorn require their notices when included in an installer. The full package lock is a reproducibility input, not a statement that every listed package is a language or an authored AppRestore module.

The demo catalog, device values and history are invented. Demo identifiers must not be submitted to Apple. Native UI artwork and the simple application icon are included for this prepared candidate; third-party app icon collections/catalog snapshots are excluded.

License interpretation references: https://www.gnu.org/licenses/gpl-faq.en.html#GPLModuleLicense and https://www.gnu.org/licenses/license-compatibility.en.html. These references do not replace preserving actual component terms or the owner decision.
