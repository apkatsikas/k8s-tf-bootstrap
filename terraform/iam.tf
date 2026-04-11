# Dedicated service account for GKE nodes.
# GKE nodes use this identity when calling GCP APIs (logging, monitoring,
# pulling images). The default Compute service account has much broader
# permissions than needed — creating a narrow one is the safer default.

resource "google_service_account" "gke_node" {
  account_id   = "gke-node"
  display_name = "GKE Node Service Account"

  depends_on = [google_project_service.iam]
}

resource "google_project_iam_member" "gke_node_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "gke_node_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

# Allows nodes to pull images from the Artifact Registry repo in this project.
resource "google_project_iam_member" "gke_node_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

# ── external-dns ──────────────────────────────────────────────────────────────
# external-dns runs in the cluster and manages Cloud DNS records automatically
# by watching HTTPRoute hostnames. It uses Workload Identity so no key files
# are needed — the Kubernetes SA is bound to this GCP SA via IAM.

resource "google_service_account" "external_dns" {
  account_id   = "external-dns"
  display_name = "external-dns"

  depends_on = [google_project_service.iam]
}

resource "google_project_iam_member" "external_dns_admin" {
  project = var.project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.external_dns.email}"
}

# Binds the Kubernetes SA external-dns/external-dns to the GCP SA above.
# Requires Workload Identity to be enabled on the cluster (see gke.tf).
resource "google_service_account_iam_member" "external_dns_workload_identity" {
  service_account_id = google_service_account.external_dns.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[external-dns/external-dns]"

  depends_on = [google_container_cluster.main]
}
