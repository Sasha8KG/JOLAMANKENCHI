# Этап 17 — проверка проекта и подготовка облачной сборки APK

- Добавлен `scripts/preflight.mjs`: 13 проверок согласованности Firebase, Android package ID, разрешений, LiveKit и серверных маршрутов.
- GitHub Actions проверяет синтаксис Worker, конфигурацию проекта, Dart analyzer, Flutter tests и собирает тестовый debug APK.
- Добавлены права GitHub Actions только на чтение, отмена устаревших запусков, тайм-аут и хранение APK 14 дней.
- Codemagic workflow также запускает preflight, анализ, тесты и debug-сборку.

## Проверено
- `node --check backend/cloudflare-worker/worker.js` — успешно.
- `node scripts/preflight.mjs` — 13/13 успешно.
- YAML GitHub Actions, Codemagic и pubspec — успешно.
- ZIP архива проверен.

## Не подтверждено
В среде нет Flutter/Dart SDK. Поэтому `flutter pub get`, `flutter analyze`, `flutter test` и `flutter build apk` ещё не запускались. APK не считается готовым до успешного облачного запуска.

## Как получить APK
После загрузки полного исходного комплекта в корень репозитория откройте Actions → Android app verification → Run workflow. После зелёного завершения скачайте артефакт `jol-aman-kenchi-debug-apk`.

Голос LiveKit требует отдельной настройки LiveKit Cloud и секретов Cloudflare. Worker также нужно отдельно развернуть. Текущий APK — debug для тестирования, не релизная подписанная версия.
