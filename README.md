# uptime-checker

A small website monitor. You add URLs, a background worker fetches each one every
minute, and a board shows which are up, which are down, and how fast they answered.

Built as the application workload for a DevSecOps pipeline project. The app is
deliberately small. The interesting part is running it: three services in two
languages, a database, a queue, and everything that needs around them.

Two more documents live in `docs/`. [decisions.md](docs/decisions.md) records
why each part is the way it is, and [runbook.md](docs/runbook.md) has the
commands for every operation this repo has needed so far.

## Services

| Service  | Language        | Job |
|----------|-----------------|-----|
| api      | Python, FastAPI | add, list and delete sites; serve current status and history |
| worker   | Go              | queue sites once a minute, fetch them, record results |
| web      | nginx, plain JS | the board; proxies `/api/` to the api container |
| migrate  | shell, psql     | applies `db/migrations` in order, then exits. alpine plus the postgres client, 20MB |
| postgres | Postgres 18     | sites and check history |
| redis    | Redis 8         | check queue and latest status per site |

## Architecture

```mermaid
graph LR
    browser(["browser"])

    subgraph runtime ["kubernetes namespace uptime, or docker compose"]
        web["web<br/>nginx, static page"]
        api["api<br/>FastAPI, 2 to 5 replicas"]
        worker["worker<br/>Go"]
        redis[("redis<br/>queue and latest status")]
        postgres[("postgres<br/>sites and check history")]
        migrate["migrate job<br/>runs once per deploy"]
    end

    sites(["monitored sites<br/>on the internet"])

    browser -->|"GET /api/sites every 5s"| web
    web -->|"proxy /api/"| api
    api -->|"sites, history"| postgres
    api -->|"read status, enqueue new site"| redis
    worker -->|"pop queue, write status"| redis
    worker -->|"read urls, write results"| postgres
    worker -->|"GET every 60s"| sites
    migrate -->|"apply db/migrations"| postgres
```

Only the worker makes outbound requests. The api and web never reach the
internet, and only the api, worker and migrate job reach the database. The
NetworkPolicies in `k8s/base/network-policies.yaml` enforce exactly that
picture, see "Network policies" under Kubernetes.

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
| `HTTP_TIMEOUT_SECONDS`   | `10`                                               | worker. the api also receives it through the ConfigMap and ignores it |
| `POSTGRES_HOST`          | `postgres`                                         | migrate, and the pod specs that assemble `DATABASE_URL` from it |
| `PGPASSWORD`             | from the Secret                                    | migrate, read by psql |
| `WEB_PORT`               | `8080`                                             | compose only, host port for the board |

## API

| Method | Path                          | Notes |
|--------|-------------------------------|-------|
| GET    | `/healthz`                    | liveness. touches nothing, always 200 while the process runs |
| GET    | `/readyz`                     | readiness. 503 with details if Postgres or Redis is unreachable |
| GET    | `/api/sites`                  | all sites with their latest status, plus the check interval |
| POST   | `/api/sites`                  | `{"url": "...", "name": "optional"}`. 201 on success, 409 if the url exists, 422 if it is not http or https |
| GET    | `/api/sites/{id}`             | one site with status. 404 if unknown |
| DELETE | `/api/sites/{id}`             | removes the site and its history. 204 on success, 404 if unknown |
| GET    | `/api/sites/{id}/checks`      | history, newest first. `?limit=` defaults to 50, up to 500. 404 if unknown |

## Run on Kubernetes

The manifests in `k8s/` deploy the same stack to a cluster. They are written for
a local [kind](https://kind.sigs.k8s.io) cluster and need `kind`, `kubectl` and
Docker. The Makefile wraps the steps:

```
make kind-up     # one node cluster named "uptime" with policy enforcement, sealed-secrets, metrics-server and argocd
make build       # build the four images with the :dev tag
make load        # copy them into the kind node, no registry involved
make deploy      # apply k8s/ and wait for everything to roll out
make status      # pods, services, jobs, volume claims
make logs-worker # follow one service
make redeploy    # after a code change: build, load, restart the services
make undeploy    # remove the namespace contents, including the database volume
make kind-down   # delete the cluster
make seal        # new random database password, sealed for the release overlay
make sealed-key-backup  # save the cluster's sealing key so a rebuilt cluster can still open it
make argocd-ui   # port-forward the argocd ui to localhost:8083
```

`make kind-up` is four installs in a row, and each is its own target for when
one component needs reinstalling without a new cluster: `network-policies-up`,
`sealed-secrets-up`, `metrics-server-up`, `argocd-up`, then `argocd-app` to
register the Application. `TAG=dev` is the image tag every target assumes and
can be overridden, `make build load TAG=test`.

Then open http://localhost:8082. That is the local overlay in namespace
`uptime-dev`. The release overlay, the one ArgoCD deploys from `main`, runs in
namespace `uptime` on the same cluster and answers on http://localhost:8081.
Compose stays on 8080, so all three can run side by side.

What is in `k8s/`:

| File                          | What it does |
|-------------------------------|--------------|
| `kind-config.yaml`            | single node. NodePort 30080 to localhost:8081 for release, 30081 to localhost:8082 for local |
| `base/kustomization.yaml`     | namespace and the resource list. no image tags |
| `base/namespace.yaml`         | `uptime`. the local overlay renames it to `uptime-dev` |
| `base/configmap.yaml`         | non-secret settings. the `.env.example` names plus `POSTGRES_HOST` and `REDIS_URL`, which compose builds inline |
| `base/postgres.yaml`          | StatefulSet with a 1Gi volume claim and a headless Service |
| `base/redis.yaml`             | Deployment, no persistence, the queue and cache rebuild themselves |
| `base/migrate-job.yaml`       | Job that applies the migrations before the services start |
| `base/api.yaml`               | liveness on `/healthz`, readiness on `/readyz`. no replica count, the autoscaler owns it |
| `base/api-hpa.yaml`           | HorizontalPodAutoscaler for the api, 2 to 5 replicas on cpu |
| `base/worker.yaml`            | 1 replica, no Service, nothing talks to it |
| `base/web.yaml`               | nginx behind a NodePort Service |
| `base/network-policies.yaml`  | default deny, then one allow per arrow in the architecture diagram |
| `overlays/local/`             | base plus the `:dev` tags of images built on this machine, and a plain Secret generated from the gitignored `secret.env`. what `make deploy` applies |
| `overlays/local/secret.env.example` | the demo password. `make deploy` copies it to `secret.env` the first time |
| `overlays/release/`           | base plus the GHCR image names, pinned to a commit by the pipeline, and the SealedSecret. what ArgoCD watches |
| `sealed-secrets/cert.pem`     | the cluster's public sealing cert. committed on purpose, anyone can seal with it and nobody can unseal |
| `sealed-secrets/key.yaml`     | the private key, gitignored. written by `make sealed-key-backup`, restored by `make kind-up` |
| `argocd/install/`             | argocd itself, pinned, with the unused controllers scaled to zero |
| `argocd/application.yaml`     | the one Application: release overlay on `main` into namespace `uptime`, automated sync |
| `metrics-server/`             | metrics-server, pinned, with the one flag kind needs |

Decisions worth knowing:

- **Liveness and readiness are different endpoints.** Liveness only says the
  process is alive. Readiness checks Postgres and Redis. If the database goes
  away, api pods drop out of the Service and come back when it returns, with
  zero restarts. Wiring both probes to the same endpoint is the common mistake
  that turns a database blip into a restart storm.
- **The database URL is assembled in the pod spec** from ConfigMap values plus
  the password from the Secret, using `$(VAR)` expansion. The password exists in
  exactly one place.
- **The base has no Secret.** Every pod reads a Secret named `uptime-db`, and
  each overlay decides how it comes to exist. The local overlay generates a
  plain one from `secret.env`, which is gitignored the same way `.env` is for
  compose. The release overlay carries a SealedSecret, see below. A committed
  password, even a demo one, is the first thing a scanner flags on a public
  repo.
- **The four first-party containers run as a numeric non-root uid** with a
  read only root filesystem and all capabilities dropped. Distroless names its
  user `nonroot`, and Kubernetes cannot verify a named user, so the worker
  states uid 65532 explicitly. The two stock images are looser on purpose:
  Postgres needs a writable data directory and its own uid handling, and Redis
  drops capabilities but keeps a writable root. What is deliberately not done
  yet: no CPU limits anywhere, only memory, because CPU throttling would
  distort the autoscaler that reads the 50m request; no seccomp profile; and
  no Pod Security Admission labels on the namespace.
- **Jobs are immutable**, so `make deploy` deletes the previous migrate Job
  before applying. ArgoCD does the same through annotations on the Job: it is
  a `Sync` hook with `hook-delete-policy: BeforeHookCreation`, so every sync
  deletes the old Job and runs a fresh one. Sync waves give the order: the
  stores in wave 0, migrate in wave 1, api, worker and web in wave 2, and
  ArgoCD waits for each wave to be healthy before starting the next. It is not
  a `PreSync` hook on purpose. On a first install Postgres does not exist
  until the Sync phase, and a PreSync migrate would wait for it forever.
- **Image tags live in the overlays, not the base.** The local overlay points
  at `uptime-checker/<service>:dev`, which is what `make build` produces. The
  release overlay points at `ghcr.io/khadirullah/uptime-checker/<service>` at a
  commit sha. A deploy is the pipeline changing that sha in a pull request and
  someone merging it. The two never collide, so a pipeline run does not break
  the local loop.

### Secrets

The release overlay is meant to be applied by a GitOps tool from this repo, so
its password has to be in git. It is, encrypted, as
`k8s/overlays/release/sealed-secret.yaml`. The
[sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) controller in
the cluster holds the only private key that can open it, and turns it into the
plain Secret the pods read. Nobody knows the password, including me: `make seal`
draws 24 random bytes as hex, pipes them through `kubeseal` and writes only
the encrypted result. Hex because the value ends up inside a `postgresql://`
URL, where base64's `/` would be read as the start of a path. Postgres and its three clients all read the same Secret, so
no human ever needs the value.

```mermaid
graph LR
    seal["make seal<br/>openssl rand -hex 24"] --> kubeseal["kubeseal --cert<br/>docker image, offline"]
    cert["cert.pem<br/>public, committed"] --> kubeseal
    kubeseal --> ss["sealed-secret.yaml<br/>encrypted, committed"]
    ss -->|"argocd applies"| ctrl["sealed-secrets controller<br/>holds the private key"]
    key["key.yaml<br/>private, gitignored,<br/>restored on cluster rebuild"] -.-> ctrl
    ctrl --> secret["Secret uptime-db"]
    secret --> postgres["postgres"]
    secret --> api["api"]
    secret --> worker["worker"]
    secret --> migrate["migrate"]
```

Two things follow from "only the cluster can open it":

- `k8s/sealed-secrets/cert.pem` is the public half and is committed. Anyone can
  seal a new value against it without cluster access. `kubeseal` runs from a
  docker image, nothing is installed.
- Deleting the cluster deletes the private key, and the committed SealedSecret
  becomes unreadable. `make sealed-key-backup` saves the key to a gitignored
  file, and `make kind-up` restores it before the controller starts, so a
  rebuilt cluster opens the same SealedSecret. A team keeps that backup in a
  vault. To move the release overlay to a different cluster instead, run
  `make sealed-key-backup` there and `make seal` again.

Why sealed-secrets and not External Secrets Operator: ESO needs a secret store
such as Vault or a cloud secret manager to fetch from, which this project does
not have and would pay for. Sealed-secrets needs nothing but the cluster.

### Network policies

`k8s/base/network-policies.yaml` starts with a default deny on ingress and
egress for every pod in the namespace, then allows one path per arrow in the
architecture diagram and nothing else:

| Pod      | May be reached by            | May reach |
|----------|------------------------------|-----------|
| web      | anyone, on 8080, which is where the NodePort lands | api on 8000 |
| api      | web, on 8000                 | postgres on 5432, redis on 6379 |
| worker   | nobody                       | postgres, redis, and the internet on 80 and 443 |
| migrate  | nobody                       | postgres on 5432 |
| postgres | api, worker, migrate on 5432 | nothing |
| redis    | api, worker on 6379          | nothing |

Every pod may also reach CoreDNS, since services are names. "The internet" for
the worker is `0.0.0.0/0` minus the private ranges and link-local, so a site
URL pointing at the cluster, the host network or a cloud metadata endpoint is
refused.

The same table as a picture. Solid arrows are the only connections allowed,
anything not drawn is dropped:

```mermaid
graph LR
    internet(["internet"])
    nodeport(["nodeport"])
    subgraph ns ["namespace uptime, default deny both ways"]
        web["web"]
        api["api"]
        worker["worker"]
        migrate["migrate"]
        postgres[("postgres")]
        redis[("redis")]
    end
    dns["coredns"]
    nodeport -->|"8080"| web
    web -->|"8000"| api
    api -->|"5432"| postgres
    api -->|"6379"| redis
    worker -->|"5432"| postgres
    worker -->|"6379"| redis
    migrate -->|"5432"| postgres
    worker -->|"80, 443, not private ranges"| internet
    web -.->|"53"| dns
    api -.->|"53"| dns
    worker -.->|"53"| dns
    migrate -.->|"53"| dns
```

Two things worth knowing:

- **kind does not enforce policies by itself.** Its default CNI routes and
  nothing more, and a deny-all policy changes nothing. `make kind-up` installs
  [kube-network-policies](https://github.com/kubernetes-sigs/kube-network-policies),
  which adds enforcement on top of the existing CNI. The same policies work
  unchanged on Calico, Cilium or a managed cluster, since they are plain
  `networking.k8s.io/v1`.
- **Test from a long-lived pod.** A one-shot pod that probes in its first
  hundred milliseconds can race the enforcer learning the pod's IP and report a
  connection that a moment later would be dropped. `kubectl run ... sleep` then
  `kubectl exec` gives a true answer.

### GitOps with ArgoCD

`k8s/argocd/application.yaml` is the whole GitOps setup: one Application that
watches `k8s/overlays/release` on `main` and keeps namespace `uptime` equal to
it. Sync is automated with prune and self heal, so `main` is the only way to
change what runs there. Scale a deployment by hand and ArgoCD scales it back
within its next reconcile.

The chain from a merge to a running pod:

1. A change under `api/` merges to `main`. The pipeline tests it, builds and
   scans the image, pushes it to GHCR, and opens a deploy pull request that
   pins the release overlay to the new tag.
2. That pull request goes through `ci-ok` and gets merged.
3. ArgoCD sees the new commit on `main`, by default within three minutes, and
   syncs. Wave 0 applies the stores, the config and the SealedSecret. Wave 1
   runs the migrate Job and waits for it to finish. Wave 2 rolls the api,
   worker and web deployments to the new image.

That order was checked on a fresh namespace: postgres and redis first, migrate
eleven seconds later once they were healthy, the three services ten seconds
after the job completed.

The whole path from a branch to a running pod:

```mermaid
graph TD
    dev["push a branch,<br/>open a pull request"] --> ci1["ci on the pull request<br/>lint, test, build, scan<br/>nothing is pushed"]
    ci1 -->|"ci-ok green, rebase and merge"| main["main"]
    main --> changes["changes<br/>which services did this touch?"]
    changes -->|"api/"| ta["test-api"]
    changes -->|"worker/"| tw["test-worker"]
    ta --> build
    tw --> build
    changes -->|"web/, db/"| build["build, one job per service<br/>hadolint, build once,<br/>trivy, push that image"]
    build --> ghcr[("ghcr.io<br/>image:sha")]
    build --> um["update-manifests<br/>pin the release overlay,<br/>open a deploy/sha pull request"]
    um -->|"ci-ok green, merge"| main2["main<br/>release overlay points at :sha"]
    main2 --> argo["argocd<br/>polls main every 3 min"]
    argo --> w0["wave 0<br/>namespace, config, sealed secret,<br/>policies, postgres, redis"]
    w0 -->|"healthy"| w1["wave 1<br/>migrate job, a sync hook"]
    w1 -->|"completed"| w2["wave 2<br/>api, worker, web<br/>rolled to :sha"]
    ghcr -.->|"pulled by"| w2
```

`make argocd-ui` port-forwards the UI to https://localhost:8083. The user is
`admin` and the target prints the command for the initial password. The dex,
notifications and applicationset controllers are scaled to zero in
`k8s/argocd/install/`, since one user with no SSO does not need them and they
would idle at about 200MB on a laptop.

### Autoscaling

`k8s/base/api-hpa.yaml` scales the api between 2 and 5 replicas on CPU, at 60
percent of the 50m request. That target is low on purpose so the behaviour can
be seen on a laptop. The Deployment carries no replica count of its own,
because a number there would be reapplied by ArgoCD on every sync and the two
would fight. The scale-down window is 60 seconds instead of the default 300,
again so a demo does not take five minutes to settle.

The autoscaler reads from metrics-server, installed by `make kind-up` from
`k8s/metrics-server/`. The one patch there, `--kubelet-insecure-tls`, is for
kind only: its kubelet serving certificates are not signed for the node IP. A
managed cluster does not need it.

`make deploy` then `kubectl -n uptime-dev get hpa -w` shows it working. Load it
from a pod the policies allow to reach the api, for example a few
`kubectl run` busybox pods labelled `app=web` looping `wget` against
`api:8000/api/sites`, and the replica count climbs within a minute. Delete
them and it comes back down about a minute later.

## Tests

These are the same commands the pipeline runs.

api, no services needed (Postgres and Redis are replaced with in-memory fakes).
`pytest.ini` turns on coverage and fails the run if it drops below 65%:

```
cd api
pip install -r requirements-dev.txt
flake8 app tests
pytest
```

worker:

```
cd worker
gofmt -l .        # prints nothing when formatted
go vet ./...
go test -race ./...
```

images, after `make build`. Both run from Docker images, nothing to install:

```
make hadolint     # Dockerfile lint
make scan         # trivy, fails on a fixable HIGH or CRITICAL
```

## Pipeline

`.github/workflows/ci.yml` runs on pull requests, on pushes to `main`, and on
a manual run.

```mermaid
graph LR
    changes["changes<br/>which services did this touch?"]
    ta["test-api<br/>flake8, pytest, coverage gate"]
    tw["test-worker<br/>gofmt, vet, test -race"]
    b["build, one per changed service<br/>hadolint, build once, trivy, push"]
    um["update-manifests<br/>pin release overlay to the sha, open a pull request"]
    ok["ci-ok<br/>the one check branch protection requires"]

    changes --> ta --> b
    changes --> tw --> b
    changes --> b
    b -->|"main only"| um
    changes --> um
    changes --> ok
    ta --> ok
    tw --> ok
    b --> ok
```

`changes` feeds every job, since each one needs to know which services are in
play.

What each stage does and why it is shaped that way:

- **Path filters.** `changes` lists the services whose files changed. A pull
  request that touches `web/` builds and scans only the web image. A change to
  `k8s/` or the README builds nothing. A change to `ci.yml` itself, or a
  manual run, builds all four.
- **Real gates.** flake8 fails the job on any finding. pytest fails below the
  coverage threshold. gofmt, vet and the race detector all fail the job. There
  is no `--exit-zero` and nothing is optional.
- **Build once.** Each image is built, loaded into the runner, scanned by its
  sha tag, and then that same image is pushed. Nothing is rebuilt between scan
  and push, so what was scanned is what ships. Scanning a `latest` tag that may
  not exist yet is the mistake this avoids.
- **Trivy fails on fixable HIGH and CRITICAL only.** A finding with no fix
  available is reported, not blocking, because there is nothing a contributor
  can do about it. The two alpine images run `apk upgrade` at build time for
  the same reason: the upstream images lag alpine's fixes by days to weeks.
- **Least permission.** The workflow token can only read the repository and
  its pull requests. The `build` job carries `packages: write`, and its login
  and push steps run only on a push to `main`. Nothing in the workflow can
  write to the repository with that token. Pull requests never push anything.
- **The deploy is a pull request.** After a push to `main`, `update-manifests`
  rewrites `newTag` in `k8s/overlays/release/kustomization.yaml` for each
  service that was rebuilt and opens a pull request with the change. It uses
  a fine-grained token scoped to this repository, stored as the
  `DEPLOY_PR_TOKEN` secret, because a pull request opened with the workflow
  token would not trigger CI. The pull request runs through `ci-ok` like any
  other, and merging it is the deploy. ArgoCD picks that merge up and rolls
  the namespace forward. The merge builds nothing because only `k8s/`
  changed, so it cannot loop.
- **One required check.** `ci-ok` is green only if no job failed or was
  cancelled, and skipped jobs count as fine. Branch protection on `main` needs
  to require just that one check, however many matrix jobs ran.
- **Pushes are never cancelled.** Pull request runs share a concurrency group
  per branch, so a new push cancels the older run, which was testing code that
  no longer exists. Runs on `main` are grouped by commit sha instead. GitHub
  keeps at most one queued run per group, and a cancelled run on `main` is an
  image that never got built or pinned.

Images are published to `ghcr.io/khadirullah/uptime-checker/<service>` tagged
with the short commit sha, plus `latest` on `main`.

`.github/dependabot.yml` opens weekly pull requests for pip, Go modules, the
base images in the four Dockerfiles, and the actions. Each one runs through the pipeline, so a
bumped base image is scanned before it is merged.

## How this maps to a real team

This repo is public, runs on one laptop, and has one contributor. A company
setup differs in known places, and each one is a swap, not a redesign:

- **The repo is private.** Nearly every company repo is. Three things change.
  ArgoCD needs a repository credential, a read-only deploy key or a token
  stored in its namespace. The cluster needs an image pull secret for GHCR,
  referenced by every pod. And branch rules need a paid plan on GitHub, since
  rulesets are not enforced on free private repos.
- **Secrets come from a store.** Sealed-secrets is the right tool when the
  cluster is the only thing you have. With Vault or a cloud secret manager, the
  External Secrets Operator replaces it: the repo holds a reference, the
  operator fetches the value at runtime, and rotation happens in the store.
- **The cluster is managed.** kind stands in for EKS, GKE or AKS. Everything in
  `k8s/` is plain Kubernetes and moves unchanged, except that a managed CNI
  enforces network policies without the extra daemonset kind needs.
- **The deploy token is an app.** The fine-grained token behind the deploy pull
  request expires yearly. A team uses a GitHub App for the same job, which
  does not expire and shows up as its own identity in the audit log.
- **Images live in the company registry**, which scans on push. Trivy in the
  pipeline stays, since failing the build is earlier and cheaper than an alert
  after the push.

## Layout

```
docs/           decision records and the runbook
.github/        the pipeline and dependabot config
api/            FastAPI service, tests, Dockerfile
worker/         Go service, tests, Dockerfile
web/            static page, nginx config, Dockerfile
db/             migrations, the script that applies them, and their Dockerfile
k8s/base/       kubernetes manifests
k8s/overlays/   local (kind, :dev images) and release (GHCR images, pinned by the pipeline)
k8s/argocd/     argocd install and the Application that deploys the release overlay
k8s/metrics-server/  metrics-server for the autoscaler
k8s/sealed-secrets/  the public sealing cert
k8s/kind-config.yaml
docker-compose.yml
Makefile        kind workflow and the image gates
```

## License

MIT, see [LICENSE](LICENSE). Copy anything here that is useful to you.
