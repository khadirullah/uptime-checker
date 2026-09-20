# Runbook

The operations this repo has needed at least once, with the exact commands.
Everything runs from the repo root. `make` targets are described in the
Makefile itself, `grep '##' Makefile` lists them.

## Bring the whole thing up from nothing

```
make kind-up      # cluster, policy enforcement, sealed-secrets, metrics-server, argocd, the Application
make build load   # the four :dev images into the node, for the local overlay
make deploy       # local overlay into uptime-dev, board on localhost:8082
```

ArgoCD deploys the release overlay into `uptime` on its own, from `main`,
within about three minutes of `make kind-up` finishing. Board on
localhost:8081. If `k8s/sealed-secrets/key.yaml` exists from an earlier
cluster, `make kind-up` restores it and the committed SealedSecret opens. If it
does not exist, the SealedSecret cannot be opened on the new cluster and the
release pods stay pending on the missing Secret. Fix: `make sealed-key-backup`
then `make seal`, commit the new `sealed-secret.yaml`, land it on `main`.

## Land a change on main

`main` requires a pull request and a green `ci-ok`. Direct pushes are
rejected, including your own.

```
git switch -c <branch>
# commit as usual
git push -u origin <branch>
```

Open the pull request on GitHub, wait for `ci-ok`, rebase and merge, delete
the branch. If the change touched a service, the merge builds and scans that
image, pushes it, and opens a deploy pull request. Merge that one too. ArgoCD
picks the merge up within three minutes.

Merge one pull request at a time. Each merge that rebuilds something opens a
deploy pull request, and two of those from overlapping runs conflict on the
same overlay lines.

## A CI run was cancelled

Only pull request runs get cancelled, and only by a newer push to the same
branch. That is intended: the older run was testing code that no longer
exists. Nothing needs doing.

Runs on `main` are never queued or cancelled. Each push has its own
concurrency group keyed on the commit sha, so a burst of merges runs every
build in parallel. An earlier version grouped them by branch, and merging
three pull requests inside a minute cancelled the middle one; its image was
never built and had to be rerun by hand. If a run on `main` is ever missing
anyway, open it on the Actions page and click "Re-run all jobs".

## A deploy pull request has a conflict

It was opened against an older `main` and another deploy pull request changed
the same line since. Close it without merging. Open the run that produced it
and rerun it; the new run pins against current `main`.

## Reseal the database password

```
make seal
git add k8s/overlays/release/sealed-secret.yaml
```

Commit and land it. Two things to know:

- Postgres reads `POSTGRES_PASSWORD` only when it initialises an empty
  volume. On a running database the new Secret value does not change the
  password, and the clients start failing. Either run
  `ALTER USER uptime WITH PASSWORD '...'` in the database before the sync, or
  delete the namespace so the volume is recreated. For this project the second
  is fine, the data is check history.
- The value is sealed against `k8s/sealed-secrets/cert.pem`. That cert is the
  current cluster's. A different cluster needs `make sealed-key-backup` run
  against it first.

## Back up and restore the sealing key

```
make sealed-key-backup   # writes k8s/sealed-secrets/key.yaml (gitignored) and cert.pem (committed)
```

Keep `key.yaml` somewhere that survives this machine. It is the only thing
that can open the committed SealedSecret. Restore is automatic: `make
kind-up` applies it before the controller starts. Restoring into a cluster
that already has a controller works too, apply the file and restart the
controller deployment.

The controller rotates its key every 30 days by default and keeps old ones,
so back up again after a rotation if the cluster lives that long.

## Move the release overlay to a different cluster

Install the sealed-secrets controller there, then from a shell pointed at
that cluster:

```
make sealed-key-backup   # its cert replaces cert.pem
make seal                # reseal against it
```

Commit both files. Nothing else in `k8s/` is cluster specific except the
`--kubelet-insecure-tls` flag in `k8s/metrics-server/`, which a managed
cluster does not need.

## Rotate the deploy token

`DEPLOY_PR_TOKEN` is a fine-grained personal access token with Contents and
Pull requests set to read and write on this repository only, one year expiry.
Generate a new one under Settings, Developer settings, Fine-grained tokens,
paste it over the existing secret under the repo's Settings, Secrets and
variables, Actions. The next run uses it. Nothing in the repo changes.

## A Dependabot pull request

It arrives with checks already run. If they are green, rebase and merge. Its
merge rebuilds and rescans that one service and opens a deploy pull request.

If the checks ran against an old workflow, or failed for a reason since fixed
on `main`, comment `@dependabot rebase` on the pull request. It force-pushes a
fresh commit and CI runs again. Other comments it understands: `@dependabot
recreate`, `@dependabot ignore this minor version`, `@dependabot ignore this
dependency`.

## ArgoCD

```
make argocd-ui   # https://localhost:8083, user admin, the target prints where the password is
```

Common states:

- `Unknown` sync status for up to three minutes after a push is the poll
  interval. Click Refresh in the UI to force it.
- `OutOfSync` that does not self heal: open the app, look at the diff. If the
  migrate hook failed, its Job is shown with the error, and `kubectl -n uptime
  logs job/migrate` has the SQL error. Fix the migration, land it, sync again.
- `Degraded`: a pod is not becoming ready. `kubectl -n uptime get pods` and
  `describe` the one that is not. A missing Secret means the SealedSecret
  did not open, see the key section above.

Deleting the Application removes everything it deployed, the finalizer on it
makes sure of that. Delete the Application, not the namespace, if you want a
clean start.

## The autoscaler does nothing

Everything below uses `uptime-dev`, the local overlay. For the release
namespace read `uptime`; the autoscaler is the same.

```
kubectl top pods -n uptime-dev
```

"Metrics API not available" means metrics-server is missing or unhealthy:
`kubectl -n kube-system get deploy metrics-server`. On kind it needs the
`--kubelet-insecure-tls` flag that `k8s/metrics-server/` adds. A target
showing `<unknown>` for the first thirty seconds after a deploy is normal.

To watch it work, load the api from pods the network policy allows:

```
for n in 1 2 3; do kubectl -n uptime-dev run load-$n --image=busybox:1.37 --restart=Never \
  --labels=app=web --command -- sh -c 'while true; do wget -q -O- http://api:8000/api/sites >/dev/null 2>&1; done'; done
kubectl -n uptime-dev get hpa api -w
kubectl -n uptime-dev delete pod load-1 load-2 load-3
```

Up within a minute, down about seventy seconds after the load stops.

## A pod cannot reach something it should

Test from a long-lived pod, never a one-shot one. A pod that probes in its
first moments can race the enforcer learning its IP and report a connection
that would be dropped a moment later. Shown for `uptime-dev`; the policies
are identical in `uptime`.

```
kubectl -n uptime-dev run probe --image=busybox:1.37 --restart=Never --labels=app=web --command -- sleep 600
kubectl -n uptime-dev exec probe -- nc -z -w 4 api 8000 && echo allowed || echo blocked
kubectl -n uptime-dev delete pod probe
```

The label decides which policy applies. The enforcer logs every verdict:
`kubectl -n kube-system logs ds/kube-network-policies --tail=20`.

## Roll back a bad deploy

Self heal is on, so `kubectl rollout undo` is reverted within minutes. The
release overlay on `main` is the only thing that decides what runs. Two ways
back:

- Revert the deploy pull request's merge commit on a branch, open a pull
  request, merge. ArgoCD rolls the affected services back to the previous
  tag. This is the normal path.
- Edit `k8s/overlays/release/kustomization.yaml` by hand to any tag that
  exists in GHCR, same branch and pull request flow. Useful when the previous
  tag is several deploys back.

Either way the migrate job runs again on the sync. Migrations are idempotent
and only add, so an older image runs fine against a newer schema.

## Add a migration

Drop a new file in `db/migrations/`, named so it sorts after the existing ones,
for example `002_add_index.sql`. Two rules, both enforced by nothing but
review:

- Every statement must be safe to run twice, `IF NOT EXISTS` and friends.
  The job runs on every deploy and on every ArgoCD sync.
- Only add. Dropping a column breaks the previous image, which is what a
  rollback deploys.

A change under `db/` rebuilds the migrate image, and the deploy pull request
pins it. On the local overlay, `make deploy` runs it immediately.

If the job fails, `kubectl -n uptime-dev logs job/migrate` has the SQL error.
Fix the file and `make deploy` again; the job is deleted and recreated each
time.

## The local code loop

```
make redeploy          # rebuild the four images, load them, restart the services
make logs-worker       # follow one service
make undeploy          # delete the namespace, including the database volume
make hadolint scan     # the two image gates the pipeline runs, before pushing
```

`make build` passes `--pull`, so Docker checks the registry for a newer base
image before every build instead of reusing the copy it already has. Without
it a base pulled two weeks ago stays in use, its packages age, and `make scan`
fails on findings the pipeline never sees, because a CI runner starts empty and
always pulls fresh.

Compose is the other local loop, without Kubernetes: `docker compose up
--build`, board on localhost:8080. The README covers it.

## Back up the database

The check history lives in the `data-postgres-0` volume claim. On kind it is
a directory on the node container and dies with the cluster. To keep it:

```
kubectl -n uptime exec postgres-0 -- pg_dump -U uptime uptime > backup.sql
kubectl -n uptime exec -i postgres-0 -- psql -U uptime uptime < backup.sql
```

The second line restores into an already migrated database, so run it after
the migrate job has completed.

## Rebuild the cluster

Needed when `k8s/kind-config.yaml` changes, port mappings cannot be added to
a running cluster.

```
make sealed-key-backup   # if not already done
make kind-down
make kind-up
make load deploy
```

About four minutes. The release namespace comes back on its own through
ArgoCD.
