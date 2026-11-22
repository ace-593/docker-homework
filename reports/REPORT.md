# Отчёт о проверках

Проверки выполнены 22 ноября 2026 года последовательно: один контейнер,
Compose с SQLite, затем два запуска финальной проверки с Redis.
Среда: Docker Desktop 4.96.0, Docker Engine 29.9.1, Linux/arm64,
Docker Compose v5.6.0. Полный вывод версий: [environment.log](environment.log).

## 4 балла

Команды (имя образа и контейнера при проверке было уникальным):

```sh
docker build -t "$image" .
docker run -d --name "$single" -p 127.0.0.1::8000 \
  -e 'GREETING=Single container check' "$image"
url="http://$(docker port "$single" 8000/tcp)"
curl -fsS "$url/"
curl -fsS -X POST "$url/increment"
docker logs "$single"
```

Получены `greeting: Single container check`, `storage: sqlite`,
`count: 0` для GET и `count: 1` для POST. В логах сервера:

```text
2026-11-22 15:04:13,145 listening port=8000 storage=sqlite
2026-11-22 15:04:14,052 http 172.17.0.1 "GET / HTTP/1.1" 200 -
2026-11-22 15:04:14,171 http 172.17.0.1 "POST /increment HTTP/1.1" 200 -
```

Время внутри логов контейнера — UTC.
Полный вывод сборки, запросов и логов: [04-06-basics.log](04-06-basics.log).

## 6 баллов

Использован `compose.sqlite.yaml`, проект `dockerhw-basics-1795359832-81264`,
`GREETING=Compose SQLite check`, `HOST_PORT=0` для свободного порта.

```sh
docker compose -p "$project" --env-file .env.example -f compose.sqlite.yaml up --build -d --wait
# Три POST /increment вернули соответственно 1, 2, 3.
docker compose -p "$project" --env-file .env.example -f compose.sqlite.yaml down
docker compose -p "$project" --env-file .env.example -f compose.sqlite.yaml up -d --wait
# Повторный GET / вернул 3.
```

Именованный volume сохранил данные после удаления контейнера.
Hostname до удаления: `8501bc565315`, после создания: `02027c695997`.
Оба ответа содержат `storage: sqlite`; финальный ответ содержит `count: 3`.

## 8 и 10 баллов

Из корня репозитория два раза подряд выполнен один и тот же скрипт:

```sh
./scripts/check.sh
./scripts/check.sh
```

Оба запуска завершились с кодом `0`, включая очистку ресурсов в `trap`.

| Прогон | Изолированный проект | Полный вывод |
| --- | --- | --- |
| 1 | `dockerhw-check-1795359886-81771` | [10-run-1.log](10-run-1.log) |
| 2 | `dockerhw-check-1795359934-82340` | [10-run-2.log](10-run-2.log) |

В обоих запусках получены одинаковые результаты:

| Проверка | Результат |
| --- | --- |
| Новое пустое Redis-хранилище | GET `/`: 200, `count: 0` |
| Три POST `/increment` | 200, значения 1, 2, 3 |
| `up --no-deps --force-recreate app` | ID app изменился, ID Redis сохранился, `count: 3` |
| `down`, затем `up -d --wait` без `-v` | GET `/`: 200, `count: 3` |
| `stop redis`, GET `/healthz` | 200, `{"status":"alive"}` |
| `stop redis`, GET `/readyz` | 503, `storage_unavailable` |
| `stop redis`, POST `/increment` | 503, `storage_unavailable` |
| `start redis`, ожидание `/readyz`, GET `/` | 200, `count: 3` |
| Следующий POST `/increment` | 200, `count: 4` |
| ID и время запуска app до и после сбоя | Не изменились; app не перезапускался |
| UID процесса app | 10001 |
| Docker HostConfig.ReadonlyRootfs | true |
| Docker HostConfig.Memory | 268435456 байт = 256 MiB |
| Docker HostConfig.NanoCpus | 1000000000 = 1 CPU |
| После `down -v` | Прежних volumes проекта нет |
| Восстановление архива в новый volume | GET `/`: 200, `count: 4`; следующий POST: 200, `count: 5` |

Команды, реализующие проверку уровня 8, находятся в `scripts/check.sh`:
`compose down`, `compose up -d --wait --wait-timeout 60`,
`compose stop redis`, `compose start redis` и HTTP-запросы с проверкой статусов.
Функция `compose` всегда передаёт уникальное имя проекта и явный путь к `compose.yaml`.

Финальная строка каждого успешного запуска:

```text
PASS: all checks and backup restoration completed.
```

## Резервные копии и очистка

Оба сервиса штатно остановлены перед копированием всего `/data` Redis.
Архивы созданы на компьютере командой `docker cp -a "$redis_id:/data/." - > "$backup"`.
Затем исходные контейнеры и volumes удалены через `down -v`, создан новый volume
и выполнено восстановление: `docker cp -a - "$redis_id:/data" < "$backup"`.
Сохранность счётчика проверена после запуска восстановленного Redis.

Размер каждого архива — 6144 байта. Они содержат `appendonlydir/` целиком
(базовый RDB, AOF и manifest) и `dump.rdb`. В архиве сохранены UID/GID `999:1000`,
режим каталога AOF `0700` и файлов `0600`.

| Локальный архив в `backups/` | SHA-256 |
| --- | --- |
| `dockerhw-check-1795359886-81771.tar` | `a9831ee5546dad1496b393a1db54b9b48c34b9092216bef7799ebe0f5bfa4bcd` |
| `dockerhw-check-1795359934-82340.tar` | `2c24974a29da6e2d71ac6f48d4f7e500e3e7fac60b0b98a76c4d1f678c768a1e` |

Архивы исключены из Git и создаются заново при каждом запуске.
После проверок отдельно подтверждено отсутствие контейнеров, volumes и сетей
всех использованных тестовых проектов.

## Неизменность исходников

Git blob SHA-1 локальных файлов совпадают с исходным заданием:

| Файл | Git blob SHA-1 |
| --- | --- |
| `app/app.py` | `85a3e5807ddf81705fdbbfbe4b0d9a896a7a02a6` |
| `app/requirements.txt` | `0cecdf573aaebc5f35cfe3a524815370f101c8f0` |
| `app/README.md` | `0a5840ee2b7d90d9eedbcbb298362b136748fd46` |
