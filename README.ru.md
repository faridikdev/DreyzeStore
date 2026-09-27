# DreyzeStore

[English](README.md) · **Русский**

DreyzeStore — открытый проект нативного каталога iOS, клиента проверки пакетов, API на Cloudflare Workers, формата репозитория и панели публикации. Проект развивается по этапам. **PHASE 6 добавляет аутентификацию администраторов, черновики приложений, приватную загрузку IPA, изолированную серверную проверку, подтверждение прав на распространение и публикацию после review.**

iOS-клиент скачивает опубликованный пакет, проверяет SHA-256 и структуру IPA, затем на совместимом устройстве может передать `VerifiedPackage` в TrollStore через документный импорт Apple. DreyzeStore сообщает **Handed Off**, поскольку не может подтвердить результат установки в принимающем приложении. Обычная sandbox-сборка iOS не может устанавливать произвольные IPA или перечислять все установленные приложения.

## Архитектура

- `ios/DreyzeStore` — SwiftUI-клиент (iOS 16+), типизированный async API, offline-кэш метаданных, скачивание пакетов, проверка SHA-256/IPA и передача только проверенного пакета.
- `backend` — Cloudflare Worker на Hono и TypeScript, D1 для метаданных, приватный R2 staging и публичный R2 distribution bucket.
- `admin` — адаптивная панель на React, TypeScript и Vite для черновиков, загрузки ресурсов, review релизов, Today/featured и публикации.
- `shared/schemas` — версионированная JSON Schema репозитория и общая проверка DTO.
- `scripts/validate_ipa.py` — изолированный ограниченный валидатор IPA, запускаемый workflow GitHub Actions.
- `.github/workflows/ci.yml` — проверки backend/admin и macOS-сборка iOS Simulator. `.github/workflows/validate-ipa.yml` — проверка выбранной загрузки с аутентификацией OIDC.

Документация: [архитектура](docs/architecture.md), [API](docs/api.md), [панель администратора](docs/admin.md), [создание первого администратора](docs/admin-bootstrap.md), [загрузка и публикация](docs/upload-pipeline.md), [валидатор](docs/validator.md), [безопасность](docs/security.md), [установка](docs/installation.md), [лицензии](docs/licenses.md), [развёртывание](docs/deployment.md).

## Требования

- Node.js 22.12+ и npm.
- Python 3 для проверки IPA и D1 migrations.
- macOS и Xcode для локальной iOS-сборки; публичный GitHub Actions workflow использует macOS runner.
- Cloudflare credentials не нужны для локального каталога и тестов. Production-ресурсы автоматически не создаются.

## Локальный backend и панель

```sh
npm ci
npm run db:migrate:local
npm run db:seed:local
npm run dev:api
```

В другом окне PowerShell настройте панель и запустите её:

```powershell
Copy-Item admin/.env.example admin/.env.local
npm run dev:admin
```

Локальный seed содержит только вымышленные метаданные и URL с зарезервированным `.invalid`. Тестовая IPA генерируется только во время теста. Полный end-to-end сценарий публикации запускается командой `npm run admin:e2e:local`: он использует in-memory хранилища, настоящий Python-валидатор и те же Hono endpoints, не сохраняя IPA в Git. Для локального входа примените миграции и выполните `npm run admin:bootstrap:local -- --email=you@example.test`; случайный пароль выводится один раз.

Скопируйте `backend/.dev.vars.example` в `backend/.dev.vars` для локальной аутентификации/upload flags, а `admin/.env.example` в `admin/.env.local` для URL панели. Для production-style проверки нужен GitHub App и настройки workflow из [документации валидатора](docs/validator.md). Секретов в репозитории нет.

## iOS

Откройте `ios/DreyzeStore/DreyzeStore.xcodeproj` в Xcode или на macOS выполните:

```sh
xcodebuild test -project ios/DreyzeStore/DreyzeStore.xcodeproj -scheme DreyzeStore \
  -destination 'platform=iOS Simulator,name=<available iPhone>' CODE_SIGNING_ALLOWED=NO
```

Debug-конфигурация использует `http://127.0.0.1:8787/api/v1`. Release пока указывает на зарезервированный `.invalid`, пока оператор не настроит одобренный публичный endpoint.

## Безопасность и права на релизы

Пароли администраторов хешируются Argon2id во внутреннем Durable Object KDF. В D1 хранится только хеш непрозрачного session token; cookie имеет HttpOnly, а изменения требуют CSRF-проверку. IPA остаётся в приватном staging, пока закреплённый GitHub Actions workflow не проверит пакет, а администратор не подтвердит метаданные и права на распространение. Опубликованные object keys неизменяемы. После скачивания iOS-клиент повторяет проверку SHA-256 и структуры IPA.

SHA-256 подтверждает целостность относительно опубликованного digest, но не доказывает безопасность, законность или отсутствие malware. Лицензия MIT проекта не предоставляет прав на приложения, иконки, скриншоты и содержимое сторонних репозиториев.

## Проверки

```sh
npm run check
npm run admin:e2e:local
```

Полная проверка включает lint, TypeScript, тесты, Python-тесты валидатора, D1 migrations, сборку Admin и Wrangler Worker dry-run. Эти команды не деплоят проект, не создают платные ресурсы, не меняют DNS и не устанавливают production secrets.
