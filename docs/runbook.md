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

The workflow keeps one running and one queued run per branch. Merging three
pull requests inside a minute cancels the middle one, shown with an
exclamation mark on the Actions page. The image from that merge was never
built or pinned.

Wait until nothing is queued, then open the cancelled run and click "Re-run
all jobs". It builds the image at that commit and opens its deploy pull
request. Do not rerun while another run is queued, the rerun joins the same
queue and cancels it.

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

```
kubectl top pods -n uptime
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
that would be dropped a moment later.

```
kubectl -n uptime run probe --image=busybox:1.37 --restart=Never --labels=app=web --command -- sleep 600
kubectl -n uptime exec probe -- nc -z -w 4 api 8000 && echo allowed || echo blocked
kubectl -n uptime delete pod probe
```

The label decides which policy applies. The enforcer logs every verdict:
`kubectl -n kube-system logs ds/kube-network-policies --tail=20`.

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
