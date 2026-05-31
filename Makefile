CLUSTER_NAME     := kind-app
GKE_CLUSTER_NAME ?= $(shell terraform -chdir=terraform output -raw cluster_name 2>/dev/null)

# GKE settings — auto-derived from terraform outputs when not set explicitly.
# IMAGE_TAG defaults to latest; use a git SHA for real deploys.
# PROJECT_ID must always be set explicitly.
REGISTRY   ?= $(shell terraform -chdir=terraform output -raw registry_url 2>/dev/null)
IMAGE_TAG  ?= latest
HOSTNAME   ?= $(shell terraform -chdir=terraform output -raw hostname 2>/dev/null)
LE_EMAIL   ?= $(shell terraform -chdir=terraform output -raw le_email 2>/dev/null)
PROJECT_ID ?=

create-cluster:
	kind get clusters | grep -q "^$(CLUSTER_NAME)$$" || kind create cluster --name $(CLUSTER_NAME) --config kind-cluster/kind.yaml

init: create-cluster
	helmfile -e kind -l tier=platform sync

# Run npm install via Docker to update package-lock.json without needing Node installed locally.
# Run manually when adding or updating npm dependencies.
install-node-modules:
	docker run --rm \
		-v $(PWD)/src:/app \
		-w /app \
		node:24-alpine \
		npm install

build:
	docker build -t api:dev .

deploy:
	kind load docker-image api:dev --name $(CLUSTER_NAME)
	helmfile -e kind -l tier=app sync
	# api:dev tag never changes, so helm won't restart pods on upgrade — force it.
	kubectl rollout restart deployment/api -n api
	kubectl rollout status deployment/api -n api --timeout=60s

logs:
	kubectl logs -n api -l app=api -f

status:
	kubectl get pods,svc,gateway,httproute -n api

all: init install-node-modules build deploy

delete-cluster:
	kind delete cluster --name $(CLUSTER_NAME)

# ── GKE targets ──────────────────────────────────────────────────────────────
# Prerequisites: gcloud authenticated, terraform.tfvars filled in.
#   gcloud auth application-default login

terraform-init:
	terraform -chdir=terraform init

terraform-validate:
	terraform -chdir=terraform validate

terraform-plan:
	terraform -chdir=terraform plan

terraform-apply:
	terraform -chdir=terraform apply

gke-configure:
	bash -c "$$(terraform -chdir=terraform output -raw configure_docker)"
	bash -c "$$(terraform -chdir=terraform output -raw configure_kubectl)"

# Install Envoy Gateway and external-dns. cert-manager is installed last in
# gke-deploy after port 80 and DNS are confirmed ready, to avoid a race where
# cert-manager fires the HTTP-01 challenge before the LB and DNS are available.
# Requires PROJECT_ID to be set.
gke-init:
	GKE_CLUSTER_NAME=$(GKE_CLUSTER_NAME) PROJECT_ID=$(PROJECT_ID) helmfile -e gke -l name=eg sync
	GKE_CLUSTER_NAME=$(GKE_CLUSTER_NAME) PROJECT_ID=$(PROJECT_ID) helmfile -e gke -l name=external-dns sync

gke-push:
	docker build -t $(REGISTRY)/api:$(IMAGE_TAG) .
	docker push $(REGISTRY)/api:$(IMAGE_TAG)

gke-deploy:
	HOSTNAME=$(HOSTNAME) helmfile -e gke -l name=infra sync
	kubectl wait gateway/gateway -n envoy-gateway-system \
		--for=jsonpath='{.status.addresses[0].value}' \
		--timeout=120s
	HOSTNAME=$(HOSTNAME) REGISTRY=$(REGISTRY) IMAGE_TAG=$(IMAGE_TAG) helmfile -e gke -l name=api sync
	# Wait for port 80 on the LB and DNS to be ready before installing cert-manager.
	# cert-manager fires the HTTP-01 challenge immediately on startup — installing it
	# last guarantees the LB and DNS are ready when the challenge is attempted.
	@LB_IP=$$(kubectl get gateway gateway -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}'); \
	echo "Waiting for port 80 on LoadBalancer $$LB_IP..."; \
	until curl -o /dev/null -s --max-time 5 -w '%{http_code}' http://$$LB_IP/ | grep -qv "^000"; do sleep 5; done
	@echo "Waiting for DNS..."
	@until dig +short $(HOSTNAME) | grep -q .; do sleep 5; done
	LE_EMAIL=$(LE_EMAIL) helmfile -e gke -l name=cert-manager sync
	LE_EMAIL=$(LE_EMAIL) helmfile -e gke -l name=cert-manager-config sync

gke-all: gke-configure gke-init gke-push gke-deploy

# Show pods, services, gateways, and cert status.
gke-status:
	kubectl get pods,svc,gateway,httproute -n api
	@echo ""
	kubectl get certificate,certificaterequest -n envoy-gateway-system
	@echo ""
	kubectl get svc -n envoy-gateway-system
	@echo ""
	kubectl get dnsendpoint,service -n external-dns

# Tear down most billable cloud infrastructure.
#
# Order matters: helm uninstall must come first so GKE has time to delete the
# cloud load balancer before terraform destroy removes the cluster. If terraform
# runs first the load balancer may be orphaned and continue accruing charges.
gke-teardown:
	helm uninstall api -n api --ignore-not-found
	helm uninstall infra -n infra --ignore-not-found
	helm uninstall external-dns -n external-dns --ignore-not-found
	helm uninstall cert-manager -n cert-manager --ignore-not-found
	helm uninstall eg -n envoy-gateway-system --ignore-not-found
	set -e; \
	DNS_ZONE=$$(terraform -chdir=terraform output -raw dns_zone_name); \
	terraform -chdir=terraform state rm google_dns_managed_zone.main; \
	terraform -chdir=terraform destroy -auto-approve; \
	terraform -chdir=terraform import google_dns_managed_zone.main $$DNS_ZONE
