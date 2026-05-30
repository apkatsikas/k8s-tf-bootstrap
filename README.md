# k8s-tf-bootstrap

Kubernetes + Terraform bootstrap for a GKE-hosted API with automated DNS and TLS.

Includes a Node.js app running on Kubernetes with TLS, Gateway API, and Helm. Works locally with KIND and deploys to GKE.

---

## Stack

| Component                                                       | Why                                                                             |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| [Envoy Gateway](https://gateway.envoyproxy.io/)                 | Implements the Gateway API                                                      |
| [cert-manager](https://cert-manager.io/)                        | Automates TLS certificate lifecycle (self-signed locally, Let's Encrypt on GKE) |
| [external-dns](https://github.com/kubernetes-sigs/external-dns) | Watches HTTPRoute hostnames and creates Cloud DNS records automatically         |
| [Terraform](https://www.terraform.io/)                          | Provisions GKE cluster, Artifact Registry, Cloud DNS zone, and IAM              |
| [KIND](https://kind.sigs.k8s.io/)                               | Runs a real Kubernetes cluster locally inside Docker                            |

Two Helm charts keep concerns separate:

- **`charts/infra`** — GatewayClass, Gateway, ClusterIssuer, EnvoyProxy (platform layer)
- **`charts/api`** — Deployment, Service, HTTPRoutes (application layer)

---

## Project Structure

```
.
├── charts/
│   ├── infra/          # Platform: GatewayClass, Gateway, ClusterIssuer, EnvoyProxy
│   └── api/            # App: Deployment, Service, HTTPRoutes
├── kind-cluster/
│   └── kind.yaml       # KIND cluster config (port mappings)
├── terraform/          # GKE cluster, registry, DNS zone, IAM
├── src/                # Node.js application source
├── Dockerfile
├── helmfile.yaml.gotmpl
└── Makefile
```

---

## Local (KIND)

### Prerequisites

| Tool                                                                 | Purpose                     |
| -------------------------------------------------------------------- | --------------------------- |
| [Docker](https://docs.docker.com/get-docker/)                        | Runs KIND and builds images |
| [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | Local Kubernetes cluster    |
| [kubectl](https://kubernetes.io/docs/tasks/tools/)                   | Talks to the cluster        |
| [helm](https://helm.sh/docs/intro/install/)                          | Deploys the charts          |
| [helmfile](https://helmfile.readthedocs.io/en/latest/#installation)  | Orchestrates helm releases  |

### Quick Start

```bash
make all
```

Runs in order: creates the KIND cluster → installs Envoy Gateway and cert-manager → installs npm dependencies → builds the Docker image → deploys both charts.

Visit `https://api.localhost`. Accept the self-signed cert warning.

### Dev Loop

```bash
make build && make deploy
```

```bash
make logs    # tail logs from the api pod
make status  # pods, services, gateway, routes in the api namespace
```

---

## GKE

### One-time prerequisites

| Tool                                                           | Purpose                   |
| -------------------------------------------------------------- | ------------------------- |
| [gcloud](https://cloud.google.com/sdk/docs/install)            | GCP CLI                   |
| [terraform](https://developer.hashicorp.com/terraform/install) | Provisions infrastructure |
| [helm](https://helm.sh/docs/intro/install/)                    | Deploys the charts        |
| [helmfile](https://helmfile.readthedocs.io/en/latest/#installation) | Orchestrates helm releases |
| [kubectl](https://kubernetes.io/docs/tasks/tools/)             | Talks to the cluster      |

Register your domain once via Cloud Domains (survives teardown):

```bash
gcloud domains registrations register yourdomain.com --project=$PROJECT_ID
```

### Deploy

1. `export PROJECT_ID=your-gcp-project-id`
2. `gcloud auth login --no-launch-browser`
3. `gcloud auth application-default login --no-launch-browser`
4. `gcloud config set project $PROJECT_ID`
5. `gcloud auth application-default set-quota-project $PROJECT_ID`
6. Fill in `terraform/terraform.tfvars`
7. `make terraform-init`
8. `make terraform-plan`
9. If the Cloud DNS zone already exists outside of Terraform state (e.g. from a previous run):
   ```bash
   terraform -chdir=terraform import google_dns_managed_zone.main andrewkatsikas-com
   ```
10. `make terraform-apply` — provisions cluster, registry, Cloud DNS zone, syncs nameservers
11. `make gke-all PROJECT_ID=$PROJECT_ID`
    > After deploy, external-dns creates the DNS A record (~1 min) and cert-manager issues the TLS cert (~2 min):
    >
    > ```bash
    > make gke-status
    > watch dig $(terraform -chdir=terraform output -raw hostname) +short
    > ```

### Teardown

```bash
make gke-teardown
```

The Cloud DNS zone is preserved (`prevent_destroy = true`) — nameservers never change and there is no propagation delay on rebuild. Start from step 7 to rebuild.

---

## How It Works

### Request path (GKE)

```
Browser
  → Cloud LoadBalancer (dynamic IP managed by GKE)
  → Envoy Gateway (TLS termination, envoy-gateway-system namespace)
  → HTTPRoute (matches hostname → api Service)
  → Service (ClusterIP, load balances across pods)
  → Pod
```

HTTP requests are redirected to HTTPS by a second HTTPRoute on the port 80 listener before reaching the app.

### Request path (KIND)

```
Browser
  → localhost:443
  → KIND extraPortMapping (host → KIND node)
  → Envoy hostPort (KIND node → Envoy pod)
  → Gateway (TLS termination)
  → HTTPRoute → Service → Pod
```

KIND has no cloud load balancer, so `kind-cluster/kind.yaml` maps host ports into the cluster and an `EnvoyProxy` resource bridges them to the Envoy pod using `hostPort`.

### TLS

cert-manager watches the Gateway annotation (`cert-manager.io/cluster-issuer`) and manages the full certificate lifecycle. Locally it issues a self-signed cert; on GKE it uses Let's Encrypt via HTTP-01 challenge over the Gateway's HTTP listener.

### DNS (GKE)

external-dns watches HTTPRoute hostnames and writes A records to Cloud DNS pointing at the Envoy LoadBalancer IP. No static IP or manual DNS records needed.

---

## Warning: kubectl context

If you run KIND locally and GKE at the same time, verify your active context before running any commands:

```bash
kubectl config current-context
kubectl config get-contexts          # list all
kubectl config use-context <name>    # switch
```

KIND contexts: `kind-<cluster>`. GKE contexts: `gke_<project>_<zone>_<cluster>`.
