# Tool — Docker-инфраструктура мониторинга и MLflow

Готовый набор сервисов для развёртывания кластера (Docker Compose / Docker Swarm): ingress через Caddy, мониторинг (Prometheus + Grafana), эксперименты ML (MLflow), S3-хранилище (MinIO) и инструменты управления (Portainer, Adminer).

## Состав сервисов

| Сервис | Образ | Порт (через Caddy) | Basic auth | Примечание |
|--------|-------|:----------:|:----------:|------------|
| caddy | `caddy:latest` | 80 / 443 | — | Ingress / reverse proxy |
| grafana | `grafana/grafana:latest` | `localhost:8081` | да | Дашборды и визуализация |
| prometheus | `prom/prometheus:latest` | `localhost:8082` | да | Сбор и хранение метрик |
| node-exporter | `prom/node-exporter:latest` | (внутренний) | нет | Метрики хостов (global mode в swarm) |
| cadvisor | `gcr.io/cadvisor/cadvisor:latest` | (внутренний) | нет | Метрики контейнеров (global mode в swarm) |
| mlflow | `ghcr.io/mlflow/mlflow:latest` | `localhost:8083` | да | Tracking server (ML-эксперименты) |
| minio | `minio/minio:latest` | `localhost:8084` | да | S3-хранилище артефактов |
| portainer | `portainer/portainer-ce:latest` | `localhost:8085` | да | Управление Docker/Swarm |
| adminer | `adminer:latest` | `localhost:8086` | да | Управление БД |
| postgres | `postgres:latest` | (внутренний) | n/a | БД для MLflow |
| redis | `redis:latest` | — | — | закомментирован |
| alertmanager | `prom/alertmanager:latest` | `localhost:8087` | да | закомментирован (уведомления) |

`node-exporter` и `cadvisor` не имеют Web-UI (отдают `/metrics` по внутренней сети), поэтому не выносятся в ingress и не закрыты basic auth.

## Структура файлов

```
Tool/
├── docker-compose.yml          # вариант для docker compose
├── docker-stack.yml            # вариант для docker stack (swarm)
├── caddy/Caddyfile             # конфиг ingress + basic auth
├── grafana/
│   └── provisioning/
│       ├── datasources/prometheus.yml   # авто-подключение Prometheus
│       └── dashboards/dashboards.yml    # провайдер дашбордов
├── prometheus/
│   ├── prometheus.yml          # scrape-конфиг
│   └── alertmanager.yml        # конфиг уведомлений (закомментирован)
├── mlflow/mlflow.env           # подключение к postgres + minio
├── minio/minio.env             # root-креды MinIO
├── postgres/initdb/01-create-mlflow.sql  # init бд/юзера mlflow
├── redis/redis.env             # (redis закомментирован)
├── portainer/                  # данные в volume
└── adminer/                    # данные в volume
```

## Требования

- Docker Engine и Docker Compose (для compose) или Swarm-кластер (для stack)
- Доступ к образам из Docker Hub / GHCR / GCR

## Быстрый старт

### 1. Создать внешнюю сеть

Для swarm (overlay-сеть, общая между нодами):

```bash
docker network create --driver overlay --attachable tool-net
```

Для compose на одной ноде достаточно обычной сети:

```bash
docker network create tool-net
```

### 2. Запуск

Вариант Docker Compose:

```bash
docker compose up -d
```

Вариант Swarm (stack):

```bash
docker stack deploy -c docker-stack.yml tool
```

Stopping (compose):

```bash
docker compose down
```

Stopping (stack):

```bash
docker stack rm tool
```

## Доступ к сервисам

После запуска Caddy проксирует следующие адреса (логин/пароль везде `admin` / `admin`):

| Адрес | Сервис |
|-------|--------|
| `http://localhost:8081` | Grafana |
| `http://localhost:8082` | Prometheus |
| `http://localhost:8083` | MLflow |
| `http://localhost:8084` | MinIO (Web-UI) |
| `http://localhost:8085` | Portainer |
| `http://localhost:8086` | Adminer |

> Порты/поддомены задаются в `caddy/Caddyfile`. Заменить `localhost:<port>` на свои поддомены при необходимости, например:
> `grafana.kuronami.fun { reverse_proxy grafana:3000 }`

## Внутренние сервисы

Доступны только внутри сети `tool-net` (по имени сервиса), не опубликованы наружу:

- **PostgreSQL** — `postgres:5432` (пользователь `mlflow` / пароль `mlflow`, бд `mlflow`)
- **MinIO S3** — `minio:9000`
- **node-exporter** — `node-exporter:9100`
- **cadvisor** — `cadvisor:8080`
- **Prometheus** — `prometheus:9090`

## Смена паролей

### Basic auth в Caddy

По умолчанию логин/пароль `admin` / `admin`. Сгенерируйте новый bcrypt-хеш:

```bash
docker run --rm caddy caddy hash-password --plaintext 'мега_пароль'
```

Вставьте полученный хеш в нужные блоки `basicauth` в `caddy/Caddyfile`.

### MinIO

Креды задаются в `minio/minio.env` (`MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`) и должны совпадать с теми, что настроены для MLflow в `mlflow/mlflow.env` (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`).

### Grafana

Дашборд Grafana использует `admin` / `admin` (env `GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD`). Сменить перед деплоем при необходимости.

### PostgreSQL

Пользователь/пароль MLflow заданы в `postgres/initdb/01-create-mlflow.sql` и должны совпадать с `MLFLOW_BACKEND_STORE_URI` в `mlflow/mlflow.env`. Креды root-postgres — в `docker-compose.yml` / `docker-stack.yml`.

## MLflow + MinIO + PostgreSQL

- **Backend store** (метаданные экспериментов) — PostgreSQL, URI:
  `postgresql://mlflow:mlflow@postgres:5432/mlflow`
- **Artifact store** — MinIO S3, бакет `mlflow`, endpoint `http://minio:9000`

Бакет `mlflow` автоматически создаётся сервисом `minio-init` при первом старте.

Пример клиента:

```python
import mlflow

mlflow.set_tracking_uri("http://localhost:8083")
mlflow.set_experiment("my-experiment")

with mlflow.start_run():
    mlflow.log_param("lr", 0.01)
    mlflow.log_metric("acc", 0.95)
    mlflow.log_artifact("model.pkl")
```

Для прокидывания MLflow-клиента во внешние контейнеры добавьте им сеть `tool-net` (overlay, `--attachable`).

## Мониторинг кластера

Пара "Prometheus + Grafana" покрывает базовый мониторинг:

- **node-exporter** собирает метрики хостов (CPU, память, диск, сеть);
- **cadvisor** — метрики контейнеров (CPU, память, сеть, I/O);
- **Grafana** — визуализация, датасорс Prometheus подключается автоматически.

В swarm-варианте оба экспортёра работают в `mode: global` — по одному на каждой ноде.

Для уведомлений (алертов) включите **alertmanager**: раскомментируйте сервис в compose/stack и настройте receiver'ы в `prometheus/alertmanager.yml` (по умолчанию — пустой webhook).

## Закомментированные сервисы

- **Redis** — раскомментируйте блок `redis` в `docker-compose.yml` / `docker-stack.yml`, при необходимости задайте параметры в `redis/redis.env`.
- **Alertmanager** — раскомментируйте блок `alertmanager`, конфиг уже лежит в `prometheus/alertmanager.yml`.

## Лейблы stack
С docker-stack.yaml контейнеры разворачиваются на нодах в соответствии с лейблами. Лейбл назначается в блок deploy/placement/constraints.
```
    deploy:
      placement:
        constraints:
          - node.role == worker
          - node.performance == medium
```
Так ограничиваются ноды, на которых запускается контейнер. При деполе убедиться, что у нод есть нужные лейблы.
