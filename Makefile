# local kubernetes workflow on kind. see README "Run on Kubernetes".
CLUSTER  := uptime
TAG      ?= dev
IMAGES   := api worker web migrate
NS       := uptime-dev   # the local overlay's namespace. argocd owns `uptime` on the same cluster.

# sealed-secrets: the controller runs in the cluster, kubeseal runs from a docker image.
# cert.pem is the cluster's public sealing cert and is committed. key.yaml is the private
# key, gitignored, saved by `make sealed-key-backup` and restored by `make kind-up`.
SEALED_VERSION := 0.40.0
SEALED_CERT    := k8s/sealed-secrets/cert.pem
SEALED_KEY     := k8s/sealed-secrets/key.yaml
SEALED_KEY_SELECTOR := sealedsecrets.bitnami.com/sealed-secrets-key=active

# kind's default cni (kindnet) routes but does not enforce NetworkPolicy. this daemonset
# from kubernetes-sigs adds the enforcement without replacing the cni.
KNP_VERSION := v1.1.1

.PHONY: kind-up kind-down build load deploy redeploy status logs-% undeploy hadolint scan \
        sealed-secrets-up sealed-key-backup seal network-policies-up argocd-up argocd-app argocd-ui

kind-up:            ## create the kind cluster with policy enforcement, sealed-secrets and argocd
	kind create cluster --config k8s/kind-config.yaml --wait 120s
	$(MAKE) network-policies-up
	$(MAKE) sealed-secrets-up
	$(MAKE) argocd-up
	$(MAKE) argocd-app

argocd-up:          ## install argocd (server-side apply, the crds are too big for client-side)
	kubectl apply --server-side -k k8s/argocd/install
	kubectl -n argocd rollout status deployment/argocd-server deployment/argocd-repo-server --timeout=300s
	kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

argocd-app:         ## register the Application: release overlay on main, into namespace uptime
	kubectl apply -f k8s/argocd/application.yaml

argocd-ui:          ## port-forward the argocd ui to localhost:8083. user admin, password from the initial secret
	@echo "password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
	kubectl -n argocd port-forward svc/argocd-server 8083:443

network-policies-up: ## install kube-network-policies so the policies in k8s/base are enforced
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/kube-network-policies/$(KNP_VERSION)/install.yaml
	kubectl -n kube-system rollout status daemonset/kube-network-policies --timeout=120s

sealed-secrets-up:  ## install the controller. a saved sealing key is restored first, so old SealedSecrets still open
	@if [ -f $(SEALED_KEY) ]; then kubectl apply -f $(SEALED_KEY); else echo "no saved sealing key at $(SEALED_KEY), the controller will generate one"; fi
	kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v$(SEALED_VERSION)/controller.yaml
	kubectl -n kube-system rollout status deployment/sealed-secrets-controller --timeout=120s

sealed-key-backup:  ## save the cluster's sealing key (gitignored) and its public cert (committed)
	kubectl -n kube-system get secret -l $(SEALED_KEY_SELECTOR) -o json \
	  | jq '{apiVersion: "v1", kind: "List", items: [.items[] | del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields)]}' \
	  > $(SEALED_KEY)
	kubectl -n kube-system get secret -l $(SEALED_KEY_SELECTOR) -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d > $(SEALED_CERT)
	@echo "saved $(SEALED_KEY) and $(SEALED_CERT)"

seal:               ## generate a random database password and seal it for the release overlay. the plaintext is never stored
	# hex, not base64: api and worker put the password inside a postgresql:// url, and base64's + / = break it
	openssl rand -hex 24 | tr -d '\n' \
	  | kubectl create secret generic uptime-db -n uptime --dry-run=client -o yaml --from-file=POSTGRES_PASSWORD=/dev/stdin \
	  | docker run --rm -i -v $(CURDIR)/$(SEALED_CERT):/cert.pem:ro bitnami/sealed-secrets-kubeseal:$(SEALED_VERSION) \
	      --cert /cert.pem --format yaml \
	  > k8s/overlays/release/sealed-secret.yaml
	@echo "wrote k8s/overlays/release/sealed-secret.yaml"

kind-down:          ## delete the kind cluster
	kind delete cluster --name $(CLUSTER)

build:              ## build the service images and the migrate image
	@for s in api worker web; do docker build -t uptime-checker/$$s:$(TAG) ./$$s || exit 1; done
	docker build -t uptime-checker/migrate:$(TAG) ./db

load:               ## copy the images into the kind node (no registry needed)
	@for s in $(IMAGES); do kind load docker-image uptime-checker/$$s:$(TAG) --name $(CLUSTER) || exit 1; done

deploy:             ## apply the manifests (a Job is immutable, so drop the old one first)
	@test -f k8s/overlays/local/secret.env || cp k8s/overlays/local/secret.env.example k8s/overlays/local/secret.env
	kubectl -n $(NS) delete job migrate --ignore-not-found
	kubectl apply -k k8s/overlays/local
	kubectl -n $(NS) rollout status statefulset/postgres --timeout=120s
	kubectl -n $(NS) wait --for=condition=complete job/migrate --timeout=120s
	kubectl -n $(NS) rollout status deployment/api deployment/worker deployment/web --timeout=120s

redeploy: build load  ## rebuild, reload, and restart the services
	kubectl -n $(NS) rollout restart deployment/api deployment/worker deployment/web
	kubectl -n $(NS) rollout status deployment/api deployment/worker deployment/web --timeout=120s

undeploy:           ## remove everything in the namespace, including the database volume
	kubectl delete -k k8s/overlays/local --ignore-not-found

status:             ## pods, services and jobs in the namespace
	kubectl -n $(NS) get pods,svc,jobs,pvc

logs-%:             ## follow logs for one service, e.g. make logs-worker
	kubectl -n $(NS) logs -f deployment/$* --all-containers

# the two image gates from the pipeline, runnable here before pushing. both use docker
# images so nothing needs installing. trivy keeps its database in a named volume.
hadolint:           ## lint the four Dockerfiles with the same rules as the pipeline
	@for d in api worker web db; do echo "== $$d"; docker run --rm -i hadolint/hadolint < $$d/Dockerfile || exit 1; done

scan:               ## trivy the built images with the pipeline's gate: fixable HIGH or CRITICAL fails
	@for s in $(IMAGES); do echo "== $$s"; docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
	  -v trivy-cache:/root/.cache/trivy aquasec/trivy:0.65.0 image --quiet --scanners vuln \
	  --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1 uptime-checker/$$s:$(TAG) || exit 1; done
