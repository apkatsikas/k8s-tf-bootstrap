CLUSTER_NAME          := kind-app
GKE_CLUSTER_NAME      ?= $(shell terraform -chdir=terraform output -raw cluster_name 2>/dev/null)
ENVOY_GATEWAY_VERSION := v1.8.0-rc.0
CERT_MANAGER_VERSION  := v1.20.2
CERT_MANAGER_SRC      ?= /home/drew/cert-manager
EXTERNAL_DNS_VERSION  := 1.20.0

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

install-envoy-gateway:
	helm upgrade --install eg \
		oci://docker.io/envoyproxy/gateway-helm \
		--version $(ENVOY_GATEWAY_VERSION) \
		--namespace envoy-gateway-system \
		--create-namespace \
		--wait

install-cert-manager:
	helm upgrade --install cert-manager \
		oci://quay.io/jetstack/charts/cert-manager \
		--version $(CERT_MANAGER_VERSION) \
		--namespace cert-manager \
		--create-namespace \
		-f charts/cert-manager-values.yaml \
		--wait

init: create-cluster install-envoy-gateway install-cert-manager

 # Run npm install via Docker to update package-lock.json without needing Node installed locally.
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
	helm upgrade --install infra ./charts/infra -f charts/infra/values-kind.yaml --wait
	helm upgrade --install api ./charts/api -f charts/api/values-kind.yaml --wait
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

install-external-dns:
	helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ --force-update
	helm upgrade --install external-dns external-dns/external-dns \
		--version $(EXTERNAL_DNS_VERSION) \
		--namespace external-dns \
		--create-namespace \
		-f charts/external-dns-values.yaml \
		--set txtOwnerId=$(GKE_CLUSTER_NAME) \
		--set "extraArgs={--google-project=$(PROJECT_ID),--gateway-listener-sets}" \
		--set 'serviceAccount.annotations.iam\.gke\.io/gcp-service-account=external-dns@$(PROJECT_ID).iam.gserviceaccount.com' \
		--wait

gke-configure:
	bash -c "$$(terraform -chdir=terraform output -raw configure_docker)"
	bash -c "$$(terraform -chdir=terraform output -raw configure_kubectl)"

install-cert-manager-dev:
	cd $(CERT_MANAGER_SRC) && make ko-deploy-certmanager \
		KO_REGISTRY=$(REGISTRY) \
		KO_HELM_VALUES_FILES=$(PWD)/charts/cert-manager-values.yaml

# Install Envoy Gateway, cert-manager, and external-dns into the GKE cluster.
# Requires PROJECT_ID to be set.
gke-init: install-envoy-gateway install-cert-manager-dev install-external-dns

gke-push:
	docker build -t $(REGISTRY)/api:$(IMAGE_TAG) .
	docker push $(REGISTRY)/api:$(IMAGE_TAG)

# Note: TLS cert issuance happens asynchronously after deploy. external-dns
# creates the DNS record once the LoadBalancer IP is assigned (~1 min), then
# cert-manager issues the cert (~2 min). Check progress with: make gke-status
gke-deploy:
	helm upgrade --install infra ./charts/infra \
		--set hostname=$(HOSTNAME) \
		--set certIssuer.email=$(LE_EMAIL) \
		--wait
	helm upgrade --install api ./charts/api \
		--set image.repository=$(REGISTRY)/api \
		--set image.tag=$(IMAGE_TAG) \
		--set hostname=$(HOSTNAME) \
		--wait

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
	helm uninstall api --ignore-not-found
	helm uninstall infra --ignore-not-found
	helm uninstall external-dns -n external-dns --ignore-not-found
	helm uninstall cert-manager -n cert-manager --ignore-not-found
	helm uninstall eg -n envoy-gateway-system --ignore-not-found
	set -e; \
	DNS_ZONE=$$(terraform -chdir=terraform output -raw dns_zone_name); \
	terraform -chdir=terraform state rm google_dns_managed_zone.main; \
	terraform -chdir=terraform destroy -auto-approve; \
	terraform -chdir=terraform import google_dns_managed_zone.main $$DNS_ZONE
