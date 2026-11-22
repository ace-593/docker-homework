# Docker: приложение со счётчиком

Решение [задания](https://github.com/Nikfilk2030/missing_semester_hse_cs/tree/main/2026/amcs/year_1/hw_3)
на 10 баллов. Исходники в `app/` взяты из задания без изменений.
Для запуска нужны Docker с плагином Compose (`docker compose`) и curl;
Python на компьютере не требуется.

## Настройки и запуск

```sh
cp .env.example .env
docker compose up --build -d --wait --wait-timeout 90
curl -fsS http://127.0.0.1:8080/
curl -fsS -X POST http://127.0.0.1:8080/increment
docker compose logs app redis
```

В `.env` можно изменить `HOST_PORT` (по умолчанию `8080`) и `GREETING`.
Если порт изменён, используйте его и в командах curl. Внутри контейнера
приложение слушает порт `8000`. На компьютере публикуется только порт приложения,
на адресе `127.0.0.1`; Redis доступен приложению по имени сервиса `redis`.

| Файл | Назначение |
| --- | --- |
| `Dockerfile` | Python 3.13, зависимости, пользователь с UID/GID 10001 |
| `compose.sqlite.yaml` | Промежуточный вариант на 6 баллов: SQLite и именованный volume |
| `compose.yaml` | Финальный вариант: app и Redis с AOF и именованным volume |
| `scripts/check.sh` | Автоматическая проверка изоляции, сохранности данных, сбоев и восстановления |
| `reports/` | Отчёт и вывод настоящих запусков |

Финальный `app` работает с корневой файловой системой только для чтения,
лимитом памяти 256 MiB и лимитом CPU 1 ядро. Healthcheck приложения проверяет
`/readyz` стандартной библиотекой Python; healthcheck Redis выполняет `redis-cli ping`.
`depends_on: condition: service_healthy` задаёт ожидание Redis при запуске.
При последующем сбое Redis приложение восстанавливает соединение самостоятельно.

## 4 балла: один контейнер

```sh
docker build -t docker-hw .
docker run -d --name dockerhw-single -p 127.0.0.1:8080:8000 \
  -e 'GREETING=Single container check' docker-hw
# Дождитесь готовности HTTP-сервера:
curl -fsS http://127.0.0.1:8080/readyz
curl -fsS http://127.0.0.1:8080/
curl -fsS -X POST http://127.0.0.1:8080/increment
docker logs dockerhw-single
docker rm -f dockerhw-single
```

В новом контейнере GET возвращает `count: 0`, первый POST — `count: 1`.
Приветствие берётся из переданной переменной `GREETING`. Этот этап использует SQLite.
Логи: [reports/04-06-basics.log](reports/04-06-basics.log).

## 6 баллов: Compose и SQLite volume

```sh
docker compose -p dockerhw-sqlite -f compose.sqlite.yaml up --build -d --wait
curl -fsS -X POST http://127.0.0.1:8080/increment
curl -fsS -X POST http://127.0.0.1:8080/increment
curl -fsS -X POST http://127.0.0.1:8080/increment
docker compose -p dockerhw-sqlite -f compose.sqlite.yaml down
docker compose -p dockerhw-sqlite -f compose.sqlite.yaml up -d --wait
curl -fsS http://127.0.0.1:8080/
```

После удаления и повторного создания контейнера остаётся `count: 3`,
поскольку `/data/counter.db` расположен в именованном volume `sqlite_data`.
Обычный `down` сохраняет volume. После проверки этот промежуточный проект
можно удалить вместе с его тестовыми данными:

```sh
docker compose -p dockerhw-sqlite -f compose.sqlite.yaml down -v
```

## 8 баллов: Redis, сохранность и готовность

В `compose.yaml` заданы `STORAGE=redis` и `REDIS_URL=redis://redis:6379/0`.
Volume `redis_data` подключён к `/data` Redis. Параметры `--appendonly yes`
и `--appendfsync always` включают AOF с синхронизацией каждой записи.
Фиксированных имён контейнеров и глобальных имён volumes в Compose нет.

```sh
docker compose up --build -d --wait
curl -fsS -X POST http://127.0.0.1:8080/increment
curl -fsS -X POST http://127.0.0.1:8080/increment
curl -fsS -X POST http://127.0.0.1:8080/increment
# Запишите текущее значение N:
curl -fsS http://127.0.0.1:8080/
docker compose down
docker compose up -d --wait
curl -fsS http://127.0.0.1:8080/  # то же N

docker compose stop redis
curl -sS -w '\nHTTP %{http_code}\n' http://127.0.0.1:8080/healthz
curl -sS -w '\nHTTP %{http_code}\n' http://127.0.0.1:8080/readyz
curl -sS -w '\nHTTP %{http_code}\n' -X POST http://127.0.0.1:8080/increment
# Ожидаются соответственно 200, 503, 503.
docker compose start redis
# После готовности Redis, без перезапуска app:
curl -fsS http://127.0.0.1:8080/readyz
curl -fsS http://127.0.0.1:8080/  # N
curl -fsS -X POST http://127.0.0.1:8080/increment  # N + 1
```

Для эксперимента с сохранностью данных используйте `down` без `-v`.
`docker compose down -v` удаляет данные выбранного проекта.

## 10 баллов: автоматическая проверка

Из корня репозитория:

```sh
./scripts/check.sh
./scripts/check.sh
```

Каждый запуск создаёт отдельный проект `dockerhw-check-<время>-<PID>`
с новым volume и случайным свободным портом. Пользовательский `.env` не
подхватывается: используются `.env.example` и тестовые переменные окружения.

Скрипт проверяет начальный `0`, три инкремента, пересоздание только `app`,
полный `down/up` с сохранением volume, недоступность Redis и восстановление
счётчика `3 → 4`. ID и время запуска `app` подтверждают, что он не перезапускался
при сбое Redis. Отдельно проверяются UID, режим файловой системы и лимиты ресурсов.

Затем скрипт штатно останавливает оба сервиса и сохраняет весь `/data` Redis
во внешний `backups/<проект>.tar` командой `docker cp -a` с сохранением структуры,
владельцев и прав. После `down -v` он проверяет отсутствие прежних volumes,
создаёт новый volume, восстанавливает архив и проверяет `count: 4`, затем `5`.
Каталог `backups/` исключён из Git; локальный архив остаётся после проверки.

У HTTP-запросов есть ограничения времени соединения и выполнения, у ожиданий
готовности — конечный срок. При ошибке выводятся этап и логи, возвращается ненулевой
код. `trap` удаляет контейнеры, сеть, volumes и локальный образ только своего
тестового проекта, включая ресурсы после восстановления.

Результаты двух последовательных запусков и команды приведены в
[отчёте](reports/REPORT.md).

Справка: [запуск зависимостей Compose](https://docs.docker.com/compose/how-tos/startup-order/),
[volumes и резервные копии](https://docs.docker.com/engine/storage/volumes/#back-up-restore-or-migrate-data-volumes),
[копирование с сохранением владельцев](https://docs.docker.com/reference/cli/docker/container/cp/).
