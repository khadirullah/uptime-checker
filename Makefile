# local kubernetes workflow on kind. see README "Run on Kubernetes".
CLUSTER  := uptime
TAG      ?= dev
IMAGES   := api worker web migrate

.PHONY: kind-up kind-down build load deploy redeploy status logs-% undeploy

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
	kubectl apply -k k8s/
	kubectl -n uptime rollout status statefulset/postgres --timeout=120s
	kubectl -n uptime wait --for=condition=complete job/migrate --timeout=120s
	kubectl -n uptime rollout status deployment/api deployment/worker deployment/web --timeout=120s

redeploy: build load  ## rebuild, reload, and restart the services
	kubectl -n uptime rollout restart deployment/api deployment/worker deployment/web
	kubectl -n uptime rollout status deployment/api deployment/worker deployment/web --timeout=120s

undeploy:           ## remove everything in the namespace, including the database volume
	kubectl delete -k k8s/ --ignore-not-found

status:             ## pods, services and jobs in the namespace
	kubectl -n uptime get pods,svc,jobs,pvc

logs-%:             ## follow logs for one service, e.g. make logs-worker
	kubectl -n uptime logs -f deployment/$* --all-containers
