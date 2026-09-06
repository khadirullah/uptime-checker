# uptime-checker

A small website monitor. You add URLs, a background worker fetches each one every
minute, and a board shows which are up, which are down, and how fast they answered.

Built as the application workload for a DevSecOps pipeline project. The app is
deliberately small. The interesting part is running it: three services in two
languages, a database, a queue, and everything that needs around them.

## Services

| Service  | Language        | Job |
|----------|-----------------|-----|
| api      | Python, FastAPI | add, list and delete sites; serve current status and history |
| worker   | Go              | queue sites once a minute, fetch them, record results |
| web      | nginx, plain JS | the board; proxies `/api/` to the api container |
| migrate  | shell, psql     | applies `db/migrations` in order, then exits |
| postgres | Postgres 18     | sites and check history |
| redis    | Redis 8         | check queue and latest status per site |

## Architecture

```mermaid
graph LR
    browser(["browser"])

    subgraph runtime ["kubernetes namespace uptime, or docker compose"]
        web["web<br/>nginx, static page"]
        api["api<br/>FastAPI, 2 replicas"]
        worker["worker<br/>Go"]
        redis[("redis<br/>queue and latest status")]
        postgres[("postgres<br/>sites and check history")]
        migrate["migrate job<br/>runs once per deploy"]
    end

    sites(["monitored sites<br/>on the internet"])

    browser -->|"GET / every 5s"| web
    web -->|"proxy /api/"| api
    api -->|"sites, history"| postgres
    api -->|"read status, enqueue new site"| redis
    worker -->|"pop queue, write status"| redis
    worker -->|"read urls, write results"| postgres
    worker -->|"GET every 60s"| sites
    migrate -->|"apply db/migrations"| postgres
```

Only the worker makes outbound requests. The api and web never reach the
internet, and only the api and worker reach the database. That split is what
the NetworkPolicies will enforce later.

How a check flows:

1. The worker's scheduler pushes every site id onto the Redis list `checks:queue`
   once per interval. A Redis lock makes sure only one worker replica does this per
   tick, so you can scale the worker out without multiplying the checks.
2. Any worker replica pops an id, fetches the URL with a timeout, and writes the
   result to the `checks` table and to `site:<id>:status` in Redis.
3. The api reads sites from Postgres and merges the latest status from Redis.
4. The web page polls the api every five seconds and repaints the tiles.

Adding a site enqueues it immediately, so the first result arrives within seconds.

There are two timers and they are separate things:

- **Check interval**, default 60 seconds. How often the worker fetches each site.
  Set `CHECK_INTERVAL_SECONDS` in `.env` and restart to change it. The board
  shows the current value in its footer.
- **Board refresh**, 5 seconds. How often the browser re-reads the api so a new
  result appears soon after the worker records it. Fixed in `web/app.js`.

## Run it

Requires Docker with the compose plugin.

```
docker compose up --build          # build images and start everything
docker compose up --build -d       # same, in the background
docker compose logs -f worker      # follow one service's logs
docker compose ps                  # status of every container
docker compose down                # stop, keep the database
docker compose down --volumes      # stop and wipe the database (the pgdata volume)
docker compose down --volumes --rmi local   # also remove the built images
```

Then open http://localhost:8080. The api is also exposed on http://localhost:8000
with interactive docs at http://localhost:8000/docs.

### Configuration

The defaults are:

| Setting                  | Default  |
|--------------------------|----------|
| `POSTGRES_USER`          | `uptime` |
| `POSTGRES_PASSWORD`      | `uptime` |
| `POSTGRES_DB`            | `uptime` |
| `CHECK_INTERVAL_SECONDS` | `60`     |
| `HTTP_TIMEOUT_SECONDS`   | `10`     |

These are fallbacks written into `docker-compose.yml` as `${NAME:-default}`.
If there is no `.env` file, compose uses them. There is no `.env` file in the
repo, so out of the box you get exactly the values above.

If you want different values, create a `.env` file from the template:

```
cp .env.example .env
```

and edit it. Compose reads `.env` from the project directory automatically and
takes values from there instead of the fallbacks. Any setting you leave out of
`.env` still uses its default.

`.env` is gitignored. The template is committed because it documents the
settings and holds no secrets. The real file is not, because that is where a
real password would go.

To see the values each container actually receives, with everything resolved:

```
docker compose config
```

### Build one image

Each service has its own Dockerfile and builds on its own.

```
docker build -t uptime-api    ./api
docker build -t uptime-worker ./worker
docker build -t uptime-web    ./web
docker build -t uptime-migrate ./db
```

### Run a service outside Docker

Useful while editing. Start only the backing services with compose, then run the
service you are working on directly. The defaults point at localhost, so no
environment variables are needed.

```
docker compose up -d postgres redis migrate
```

api:

```
cd api
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000
```

worker:

```
cd worker
go run .
```

web has no build step. Open `web/index.html` through any static server that can
proxy `/api/` to port 8000, or just run it in compose:

```
docker compose up -d --build web
```

Environment variables, all optional:

| Variable                 | Default                                            | Used by |
|--------------------------|----------------------------------------------------|---------|
| `DATABASE_URL`           | `postgresql://uptime:uptime@localhost:5432/uptime` | api, worker |
| `REDIS_URL`              | `redis://localhost:6379/0`                         | api, worker |
| `CHECK_INTERVAL_SECONDS` | `60`                                               | worker, api (display only) |
| `HTTP_TIMEOUT_SECONDS`   | `10`                                               | worker |
| `WEB_PORT`               | `8080`                                             | compose only, host port for the board |

## API

| Method | Path                          | Notes |
|--------|-------------------------------|-------|
| GET    | `/healthz`                    | liveness. touches nothing, always 200 while the process runs |
| GET    | `/readyz`                     | readiness. 503 with details if Postgres or Redis is unreachable |
| GET    | `/api/sites`                  | all sites with their latest status, plus the check interval |
| POST   | `/api/sites`                  | `{"url": "...", "name": "optional"}`. 409 if the url exists |
| GET    | `/api/sites/{id}`             | one site with status |
| DELETE | `/api/sites/{id}`             | removes the site and its history |
| GET    | `/api/sites/{id}/checks`      | history, newest first. `?limit=` up to 500 |

## Run on Kubernetes

The manifests in `k8s/` deploy the same stack to a cluster. They are written for
a local [kind](https://kind.sigs.k8s.io) cluster and need `kind`, `kubectl` and
Docker. The Makefile wraps the steps:

```
make kind-up     # one node cluster named "uptime", board mapped to localhost:8081
make build       # build the four images with the :dev tag
make load        # copy them into the kind node, no registry involved
make deploy      # apply k8s/ and wait for everything to roll out
make status      # pods, services, jobs, volume claims
make logs-worker # follow one service
make redeploy    # after a code change: build, load, restart the services
make undeploy    # remove the namespace contents, including the database volume
make kind-down   # delete the cluster
```

Then open http://localhost:8081. Compose and kind can run side by side, compose
stays on 8080.

What is in `k8s/`:

| File                   | What it does |
|------------------------|--------------|
| `kind-config.yaml`     | single node, NodePort 30080 mapped to localhost:8081 |
| `kustomization.yaml`   | namespace, resource list, image tags in one place |
| `namespace.yaml`       | everything lives in `uptime` |
| `configmap.yaml`       | non-secret settings, same names as `.env.example` |
| `secret.yaml`          | the database password. demo value, replaced by a SealedSecret later |
| `postgres.yaml`        | StatefulSet with a 1Gi volume claim and a headless Service |
| `redis.yaml`           | Deployment, no persistence, the queue and cache rebuild themselves |
| `migrate-job.yaml`     | Job that applies the migrations before the services start |
| `api.yaml`             | 2 replicas, liveness on `/healthz`, readiness on `/readyz` |
| `worker.yaml`          | 1 replica, no Service, nothing talks to it |
| `web.yaml`             | nginx behind a NodePort Service |

Decisions worth knowing:

- **Liveness and readiness are different endpoints.** Liveness only says the
  process is alive. Readiness checks Postgres and Redis. If the database goes
  away, api pods drop out of the Service and come back when it returns, with
  zero restarts. Wiring both probes to the same endpoint is the common mistake
  that turns a database blip into a restart storm.
- **The database URL is assembled in the pod spec** from ConfigMap values plus
  the password from the Secret, using `$(VAR)` expansion. The password exists in
  exactly one place.
- **Every container runs as a numeric non-root uid** with a read only root
  filesystem and all capabilities dropped. Distroless names its user `nonroot`,
  and Kubernetes cannot verify a named user, so the worker states uid 65532
  explicitly.
- **Jobs are immutable**, so `make deploy` deletes the previous migrate Job
  before applying. The pipeline will do the same through an ArgoCD hook.
- **Image tags live in `kustomization.yaml`.** A deploy is a change to those
  lines, which is what the pipeline will commit.

## Tests

api, no services needed (Postgres and Redis are replaced with in-memory fakes):

```
cd api
pip install -r requirements-dev.txt
flake8 app tests
pytest
```

worker:

```
cd worker
go vet ./...
go test ./...
```

## Layout

```
api/            FastAPI service, tests, Dockerfile
worker/         Go service, tests, Dockerfile
web/            static page, nginx config, Dockerfile
db/             migrations, the script that applies them, and their Dockerfile
k8s/            kubernetes manifests and the kind cluster config
docker-compose.yml
Makefile        kind workflow
```
