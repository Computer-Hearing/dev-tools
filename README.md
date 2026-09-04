# Tool — Docker-инфраструктура мониторинга и MLflow

Набор сервисов для развёртывания кластера (Docker Compose / Docker Swarm): ingress через Caddy, мониторинг (Prometheus + Grafana), эксперименты ML (MLflow), S3-хранилище (MinIO) и инструменты управления (Yacht, Adminer).

## Состав сервисов

| Сервис | Образ | Basic auth / JWT | Примечание |
|--------|-------|:----------:|------------|
| caddy | `caddy:latest` | — | Ingress / reverse proxy |
| grafana | `grafana/grafana:latest` | да | Дашборды и визуализация |
| prometheus | `prom/prometheus:latest` | да | Сбор и хранение метрик |
| node-exporter | `prom/node-exporter:latest` | нет | Метрики хостов (global mode в swarm) |
| cadvisor | `gcr.io/cadvisor/cadvisor:latest` | нет | Метрики контейнеров (global mode в swarm) |
| mlflow | `ghcr.io/mlflow/mlflow:latest` | да | Tracking server (ML-эксперименты) |
| minio | `minio/minio:latest` | да | S3-хранилище артефактов |
| yacht | `selfhostedpro/yacht:latest` | да | Управление Docker/Swarm |
| adminer | `adminer:latest` | да | Управление БД |
| postgres | `postgres:latest` | n/a | БД для MLflow |
| redis | `redis:latest` | — | закомментирован |
| alertmanager | `prom/alertmanager:latest` | да | закомментирован (уведомления) |

`node-exporter` и `cadvisor` не имеют Web-UI (отдают `/metrics` по внутренней сети), поэтому не выносятся в ingress и не закрыты auth.

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
├── yacht/                  # данные в volume
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
docker stack deploy -c docker-stack.yml dev-tools
```

### Регистрация конфигов (только для swarm)

Swarm не поддерживает локальные bind-пути и `env_file` — все файлы конфигурации передаются через `docker config create`. Перед первым деплоем стека (или после изменения любого файла конфига) выполните:

```bash
docker config create caddy_caddyfile ./caddy/Caddyfile
docker config create prometheus_conf ./prometheus/prometheus.yml
docker config create prometheus_alerts ./prometheus/alertmanager.yml
docker config create grafana_datasource ./grafana/provisioning/datasources/prometheus.yml
docker config create grafana_dashboards_provider ./grafana/provisioning/dashboards/dashboards.yml
docker config create postgres_init_mlflow ./postgres/initdb/01-create-mlflow.sql
```

> При изменении конфига создайте его заново с тем же именем с флагом `--force` (`docker config create --force ...`) либо удалите старый `docker config rm <name>`, а затем передеплойстек: `docker stack deploy -c docker-stack.yml tool`.
>
> Имена конфигов, объявленных в `configs:` в `docker-stack.yml`, должны существовать в кластере, иначе деплой упадёт.

Stopping (compose):

```bash
docker compose down
```

Stopping (stack):

```bash
docker stack rm tool
```

> Порты/поддомены задаются в `caddy/Caddyfile`. Замените `localhost:<port>` на свои домены, например:
> `grafana.example.com { reverse_proxy grafana:3000 }`

## Внутренние сервисы

Доступны только внутри сети `tool-net` (по имени сервиса), не опубликованы наружу:

- **PostgreSQL** — `postgres:5432`
- **MinIO S3** — `minio:9000`
- **node-exporter** — `node-exporter:9100`
- **cadvisor** — `cadvisor:8080`
- **Prometheus** — `prometheus:9090`

### MinIO

Креды задаются в `minio/minio.env` (`MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`) и должны совпадать с теми, что настроены для MLflow в `mlflow/mlflow.env` (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`).

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

## Лейблы stack
С docker-stack.yaml контейнеры разворачиваются на нодах в соответствии с лейблами. Лейбл назначается в блок deploy/placement/constraints.
```
    deploy:
      placement:
        constraints:
          - node.lables.role == worker
          - node.labels.performance == medium
```
Так ограничиваются ноды, на которых запускается контейнер. При деполе убедиться, что у нод есть нужные лейблы.
