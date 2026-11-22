# rc-photo-client

Flutter-приложение для телефонов (Android, позже iOS) поверх RustCloud и плагина rc-photo.
Решения и порядок работы — [PLAN.md](PLAN.md) (раздел 1 не пересматриваем), будущие вопросы — там же,
раздел 11.

- Меняем только этот репозиторий. Соседние `../r-image` (плагин), `../rustcloud` (сервер),
  `../rc-client` — только читать. Что нужно от них — в [docs/requests.md](docs/requests.md)
  (зачем, что предлагается, как приложение обходится без этого).
- Пушить можно прямо в `main` (`git@github.com:RustCloud/rc-photo-client.git`).
- Интерфейс — по мотивам Google Фото, но своя реализация.
- Локально нет Flutter, Docker и Gradle. Сборка и тесты — на buildserver в
  `/root/build/rc-photo-client`: синхронизировать файлы (`tar` по ssh, без `.dart_tool` и `build`),
  затем `sh tools/buildserver-ci.sh [test]`. Форматировать — `sh tools/buildserver-ci.sh -- dart format lib test`.
- `lib/api` — чистый Dart, без импорта Flutter: его тесты должны уметь идти против настоящего
  сервера.
- Тексты интерфейса — только через `lib/l10n/app_{en,ru}.arb`.
- Комментарии в коде — по-английски, документы — по-русски.
