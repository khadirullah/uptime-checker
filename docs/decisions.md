# Decisions

Short records of the choices that shaped this repo, in the order they were made.
Each one says what the situation was, what was chosen, and what it costs. The
point is that the reasoning survives, not just the result.

## 1. One workflow, path filtered

**Situation.** Four images, two test suites, one repo. A change to the web page
should not rebuild the Go worker.

**Decision.** A single `ci.yml` whose first job asks which services the change
touched, and every later job keys off that answer. A manual run builds all four.

**Cost.** The filter needs `pull-requests: read` on pull requests, which was
missed at first and turned every pull request red in thirteen seconds. Fixed in
one line.

## 2. Build once, scan that, push that

**Situation.** Scanning a `latest` tag that may not exist yet, or rebuilding
between scan and push, means what was scanned is not what ships.

**Decision.** Each image is built and loaded into the runner, scanned by its
sha tag, and that same image is pushed. Nothing is rebuilt in between.

**Cost.** `load: true` keeps the image on the runner, which is slower than a
pure registry push. Seconds, not minutes.

## 3. Trivy fails only on fixable HIGH and CRITICAL

**Situation.** A vulnerability with no fix available cannot be acted on by a
contributor, and a gate nobody can pass gets disabled.

**Decision.** `ignore-unfixed: true`. Unfixed findings are printed, not
blocking. The alpine images run `apk upgrade` at build time because the
upstream images lag alpine's fixes by days to weeks.

**Cost.** A real unfixed CRITICAL is visible but does not stop a merge. That is
the honest state of things.

## 4. The deploy is a pull request, not a bot commit

**Situation.** The first version had the pipeline commit the pinned image tags
straight to `main` with the workflow token. That needs write access on `main`,
cannot pass a required status check, and gives nobody a chance to look.

**Decision.** The pipeline writes the pin to a `deploy/<sha>` branch and opens
a pull request with a fine-grained token. The pull request runs through
`ci-ok` like any other, and merging it is the deploy.

**Cost.** One token to rotate yearly, because a pull request opened with the
built-in token does not trigger CI. A GitHub App would remove the expiry.

## 5. Sealed-secrets, not External Secrets

**Situation.** The release overlay is applied from git, so its password has
to be in git.

**Decision.** Bitnami sealed-secrets. The cluster holds the only key that can
open the committed value. The public cert is committed so anyone can seal; the
private key is backed up outside git and restored on cluster rebuild.

**Cost.** The secret is tied to one cluster's key. Moving to another cluster
means resealing. External Secrets Operator would fetch from a store at runtime
and rotate there, but it needs a store, which this project does not have.

## 6. The generated password is hex

**Situation.** The first sealed password was base64 of random bytes and
contained a slash. The api and worker put the password inside a
`postgresql://` URL, and the worker parsed everything after the slash as a
port. The migrate job worked because it passes `PGPASSWORD` as a plain
variable, which made the failure confusing.

**Decision.** `openssl rand -hex 24`. Forty-eight characters, none of them
special.

**Cost.** None. The lesson is general: anything that lands inside a URL is
URL-safe or percent-encoded.

## 7. The base has no Secret

**Situation.** A committed demo password, even a documented one, is the first
thing a scanner or a reviewer flags on a public repo.

**Decision.** Every pod reads a Secret named `uptime-db`, and each overlay
decides how it exists. Local generates a plain one from a gitignored file.
Release carries the SealedSecret.

**Cost.** Kustomize's `namespace:` in the base does not reach resources an
overlay adds, so each overlay states its namespace again. Found the hard way
when the generated Secret landed in `default`.

## 8. Default deny, one allow per arrow

**Situation.** The architecture diagram says only the worker reaches the
internet and only three pods reach the database. Nothing enforced it.

**Decision.** Network policies that start from deny-all in both directions and
allow exactly the arrows in the diagram, plus DNS for everyone.

**Cost.** kind's default CNI does not enforce policies at all. A deny-all
changed nothing until kube-network-policies was installed. The policies are
plain `networking.k8s.io/v1` and move unchanged to any CNI that enforces.

## 9. kube-network-policies, not Calico or Cilium

**Situation.** Enforcement on kind needs something more than kindnet.

**Decision.** The kubernetes-sigs enforcer, a single daemonset on top of the
existing CNI. No cluster recreate, no CNI swap, nothing else changes.

**Cost.** It is an enforcer, not a full CNI. No observability, no L7. A
managed cluster brings its own and this daemonset simply is not installed.

## 10. Migrate is a Sync hook in wave 1, not a PreSync hook

**Situation.** Jobs are immutable, and the migration must run after Postgres
is up and before the services start.

**Decision.** `hook: Sync`, `hook-delete-policy: BeforeHookCreation`,
`sync-wave: "1"`. Stores in wave 0, services in wave 2. ArgoCD waits for each
wave to be healthy before starting the next.

**Cost.** Slightly more annotation than PreSync. PreSync was rejected because
on a first install Postgres does not exist until the Sync phase, and a PreSync
migrate would wait for it forever.

## 11. Two namespaces on one cluster

**Situation.** ArgoCD with self-heal on owns the namespace it deploys to. A
local `make deploy` into the same namespace is reverted on the next sync.

**Decision.** The release overlay runs in `uptime` on localhost 8081 under
ArgoCD. The local overlay renames the namespace to `uptime-dev` and takes a
second NodePort on 8082. Both run at once.

**Cost.** A second port mapping in the kind config, which needs a new cluster.
The sealing key backup made that a four-minute operation.

## 12. The Deployment has no replica count

**Situation.** A HorizontalPodAutoscaler changes `spec.replicas`. A number in
the manifest is reapplied by ArgoCD on every sync, and the two fight forever.

**Decision.** Remove the field. Kubernetes defaults to one, and the autoscaler
lifts it to its minimum within one metrics cycle.

**Cost.** One brief dip to a single replica on the sync that removes the
field. Observed once, expected, and never again.

## 13. ArgoCD's unused controllers are scaled to zero

**Situation.** One user, no SSO, no notifications, no ApplicationSets, and an
8GB laptop.

**Decision.** dex, the notifications controller and the applicationset
controller run at zero replicas through a kustomize patch on the upstream
install.

**Cost.** Turning any of them on later is one line. About 200MB saved now.

## 14. Push runs are grouped by sha, pull request runs by branch

**Situation.** GitHub keeps one running and one queued run per concurrency
group. With one group per branch, merging three pull requests inside a
minute cancelled the middle run, and its image was never built or pinned.

**Decision.** Push runs use the commit sha as the group, so every merge
builds. Pull request runs keep the branch as the group and cancel their older
sibling, since only the latest push to a pull request matters.

**Cost.** A burst of merges runs several builds at once instead of queueing.
On the free runner pool that is fine.

## 15. The migrate image is alpine plus the postgres client

**Situation.** The migration job needs `psql` and nothing else. The
`postgres:18-alpine` image is 433MB.

**Decision.** `alpine` plus `postgresql18-client`, 21MB, with `apk upgrade` at
build time so the scan stays clean between upstream rebuilds.

**Cost.** A second alpine version to track. Dependabot watches it.

## 16. Distroless for the worker, nginx-unprivileged for the web

**Situation.** The worker is a static Go binary. nginx's stock image starts as
root and drops privileges itself, which Kubernetes cannot verify.

**Decision.** The worker ships on `gcr.io/distroless/static`, no shell, no
package manager. The web image is `nginxinc/nginx-unprivileged`, which listens
on 8080 and runs as its own user from the start.

**Cost.** No shell in the worker means `kubectl exec` debugging happens from a
separate probe pod. That is the point.

## 17. Numeric uids, stated in the manifest

**Situation.** `runAsNonRoot: true` makes the kubelet verify the uid, and it
cannot verify a named user like distroless's `nonroot`.

**Decision.** api runs as 10001, migrate as 10002, worker as 65532, all set
in the Dockerfile and stated numerically where the kubelet needs it.

**Cost.** A number to keep in sync between Dockerfile and manifest.

## 18. Liveness and readiness are different endpoints

**Situation.** Wiring both probes to one endpoint that checks the database
turns a database blip into a restart storm.

**Decision.** `/healthz` only says the process is alive. `/readyz` checks
Postgres and Redis. When the database goes away, api pods drop out of the
Service and come back when it returns, with zero restarts. The worker has no
probes yet; it retries its stores at startup and the fix, a small health
endpoint, is noted in its manifest.

**Cost.** Two endpoints instead of one.

## 19. Postgres behind a headless Service, Redis without persistence

**Situation.** One Postgres replica in a StatefulSet, one Redis holding a queue
and a cache.

**Decision.** The Postgres Service has no cluster IP, so the pod gets a stable
DNS name of its own. Redis has no volume: the queue refills on the next
scheduler tick and the status cache is rebuilt from Postgres.

**Cost.** A Redis restart loses at most one minute of checks.

## 20. Memory limits only

**Situation.** The autoscaler reads CPU usage against the 50m request.

**Decision.** Every container has a memory limit and no CPU limit. CPU
throttling would distort the very number the autoscaler scales on.

**Cost.** A runaway container can take CPU from its neighbours. On one node
with requests set, the scheduler still keeps the sum honest.

## 21. Actions pinned to version tags, not commit shas

**Situation.** A tag can be moved by the action's maintainer; a sha cannot.

**Decision.** Version tags, with Dependabot bumping them weekly. Readable
diffs won over the last step of supply-chain rigour for a one-person repo.

**Cost.** A compromised upstream tag would be pulled on the next run. Moving
to shas is a find and replace and a Dependabot setting.

## 22. Public repo, public images, no changelog

**Situation.** A portfolio repo exists to be read. Private repos need a
credential for ArgoCD, a pull secret for the cluster, and a paid plan for
branch rules.

**Decision.** Public, with the four GHCR packages public too, since package
visibility does not follow the repo. No `CHANGELOG.md`: the history is a
straight line of commits that say what and why, and tagged releases get
generated notes from them.

**Cost.** The demo password from the first version is visible in git history.
It was a documented placeholder and has been replaced by the sealed one.
