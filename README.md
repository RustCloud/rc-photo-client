# RustCloud Photos

Приложение для телефонов: галерея и резервная копия фото поверх [RustCloud](https://github.com/RustCloud/server)
и плагина [rc-photo](https://github.com/RustCloud/rc-photo). Сначала Android, потом iOS.

**Статус: ранняя разработка.** Что и в каком порядке делаем — [PLAN.md](PLAN.md).

- Галерея (лента, избранное, люди, истории, поиск) — из API плагина `/app/rc-photo/api/…`.
- Резервная копия с телефона — прямо в облако через `/api/v1/files/…`, плагин индексирует
  загруженное сам.
- Вход — через аккаунт приложения [RustCloud](https://github.com/RustCloud/client) на телефоне
  или своим входом через браузер (OAuth 2.0 + PKCE).

## Сборка

Нужен Flutter 3.44 и Android SDK (JDK 17).

```sh
sh ci.sh         # анализ, формат, тесты, debug-APK в out/
sh ci.sh test    # без APK
```

Без локального Flutter — в Docker-образе `ghcr.io/cirruslabs/flutter:3.44.0`:

```sh
sh tools/docker-ci.sh
```

## Проверка сервера

`tools/api-check.sh` поднимает чистый RustCloud с плагином в Docker и проверяет всё, на что
опирается приложение: вход по PKCE со схемой приложения, маршруты плагина с токеном, загрузку,
индексацию, ссылки. Нужны Docker, curl и python3.

```sh
sh tools/api-check.sh [образ сервера] [rc-photo.zip] [photo.jpg] [video.mp4]
```

С `FIXTURES=<папка>` скрипт сохраняет настоящие ответы сервера. Из них сделаны фикстуры тестов
в `test/fixtures/`.

## Устройство

```text
lib/api/    модели и клиент сервера и плагина, чистый Dart
lib/ui/     экраны
lib/l10n/   тексты: русский и английский
android/    Android-часть (applicationId com.rustcloud.photos)
docs/       запросы к плагину и серверу
tools/      проверки и сборка на buildserver
```
