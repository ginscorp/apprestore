# Presentation assets / Наглядные материалы

These images show native SwiftUI views of AppRestore 0.8.8-public.1, rendered on macOS using only the public demo catalog and invented device/history fixtures. They are not photographs of a connected iPhone, a live Apple session or a physical-device acceptance test. Preview bridges reject Apple and USB calls. The English/Russian covers arrange these exact native screenshots; decorative desktop frames do not represent a different build.

Кадры показывают нативные SwiftUI-представления AppRestore 0.8.8-public.1 на macOS с вымышленными каталогом, устройством и историей. Реальное подключение iPhone, вход Apple и приемка устройств ими не подтверждаются. Мосты Apple/USB в демо заблокированы. Обложки EN/RU используют эти же реальные кадры; декоративные рамки не заменяют поставляемый интерфейс.

- overview-en.png: English overview, synthetic storage/content values.
- overview-ru.png: Russian overview in the dark theme.
- catalog-en.png: English catalog with invented demo entries.
- battery-en.png: synthetic battery metrics and 30 persisted/reopened SQLite samples.
- passport-en.png: native technical passport component with explicitly fake details.
- hero-en.png / hero-ru.png: localized 1280×640 cover composition.

Native capture uses demo/ScreenshotHarness.swift and tools/build.py capture. Always choose a new external test directory for build/capture, set APPRESTORE_DATA_HOME, APPRESTORE_TEST_LIBRARY and APPRESTORE_TEST_ACCOUNTS to isolated synthetic locations, and run only the generated capture executable with a new output directory. Do not reuse personal profiles, accounts, databases or device observations to recreate these images.

Images and code follow the root GPL-3.0-only license; upstream assets retain their own terms. Preserve synthetic fixtures and regenerate affected images whenever the actual interface changes. Capture/export hashes and metadata review should accompany each visual release.
