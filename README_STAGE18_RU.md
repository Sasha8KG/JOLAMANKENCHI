# Этап 18 — защита release-подписи Android

- Убрана подпись release APK отладочным Android debug-ключом.
- Release task требует keystore и четыре защищённые переменные окружения.
- Добавлены исключения keystore и key.properties в .gitignore.
- Добавлена инструкция владельцу по безопасному созданию и хранению ключа.

## Проверки

- Preflight Stage 17: 13/13.
- node --check Worker: успешно.
- YAML GitHub Actions, Codemagic и pubspec: успешно.
- ZIP целостен.
- APK не собирался: Flutter SDK отсутствует в среде.

## Действие владельца позднее

Создать личный keystore на защищённом компьютере и добавить четыре значения в секреты CI. Не передавать ключ или пароли в чат и не коммитить их в GitHub.
