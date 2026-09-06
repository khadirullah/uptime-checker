# local kubernetes workflow on kind. see README "Run on Kubernetes".
CLUSTER  := uptime
TAG      ?= dev
IMAGES   := api worker web migrate

.PHONY: kind-up kind-down build load deploy redeploy status logs-% undeploy hadolint scan

kind-up:            ## create the kind cluster
	kind create cluster --config k8s/kind-config.yaml --wait 120s

kind-down:          ## delete the kind cluster
	kind delete cluster --name $(CLUSTER)

build:              ## build the service images and the migrate image
	@for s in api worker web; do docker build -t uptime-checker/$$s:$(TAG) ./$$s || exit 1; done
	docker build -t uptime-checker/migrate:$(TAG) ./db

load:               ## copy the images into the kind node (no registry needed)
	@for s in $(IMAGES); do kind load docker-image uptime-checker/$$s:$(TAG) --name $(CLUSTER) || exit 1; done

deploy:             ## apply the manifests (a Job is immutable, so drop the old one first)
	kubectl -n uptime delete job migrate --ignore-not-found
	kubectl apply -k k8s/overlays/local
	kubectl -n uptime rollout status statefulset/postgres --timeout=120s
	kubectl -n uptime wait --for=condition=complete job/migrate --timeout=120s
	kubectl -n uptime rollout status deployment/api deployment/worker deployment/web --timeout=120s

redeploy: build load  ## rebuild, reload, and restart the services
	kubectl -n uptime rollout restart deployment/api deployment/worker deployment/web
	kubectl -n uptime rollout status deployment/api deployment/worker deployment/web --timeout=120s

undeploy:           ## remove everything in the namespace, including the database volume
	kubectl delete -k k8s/overlays/local --ignore-not-found

status:             ## pods, services and jobs in the namespace
	kubectl -n uptime get pods,svc,jobs,pvc

logs-%:             ## follow logs for one service, e.g. make logs-worker
	kubectl -n uptime logs -f deployment/$* --all-containers

# the two image gates from the pipeline, runnable here before pushing. both use docker
# images so nothing needs installing. trivy keeps its database in a named volume.
hadolint:           ## lint the four Dockerfiles with the same rules as the pipeline
	@for d in api worker web db; do echo "== $$d"; docker run --rm -i hadolint/hadolint < $$d/Dockerfile || exit 1; done

scan:               ## trivy the built images with the pipeline's gate: fixable HIGH or CRITICAL fails
	@for s in $(IMAGES); do echo "== $$s"; docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
	  -v trivy-cache:/root/.cache/trivy aquasec/trivy:0.65.0 image --quiet --scanners vuln \
	  --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1 uptime-checker/$$s:$(TAG) || exit 1; done
