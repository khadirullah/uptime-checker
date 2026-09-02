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
| postgres | Postgres 18     | sites and check history |
| redis    | Redis 8         | check queue and latest status per site |

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
docker compose down -v             # stop and wipe the database
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
db/migrations/  SQL applied at startup
docker-compose.yml
```
