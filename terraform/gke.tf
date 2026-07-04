resource "google_container_cluster" "main" {
  name     = var.cluster_name
  location = var.zone # zonal = one control plane = cheapest; regional = 3 zones

  # We manage a separate node pool below so we can configure it precisely.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Allows `terraform destroy` to remove the cluster without manual steps.
  deletion_protection = false

  # Required for Workload Identity — lets Kubernetes SAs impersonate GCP SAs
  # without key files. Used by external-dns to manage Cloud DNS records.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  depends_on = [google_project_service.container]
}

resource "google_container_node_pool" "main" {
  name     = "main"
  cluster  = google_container_cluster.main.name
  location = var.zone

  node_count = 1

  node_config {
    machine_type = "e2-custom-2-6144"

    service_account = google_service_account.gke_node.email
    # cloud-platform scope lets the node SA use any GCP API that IAM allows.
    # The narrow IAM roles in iam.tf are what actually limit access.
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # Spot instances are preemptible (GKE reschedules pods automatically)
    # and ~70% cheaper than on-demand. Fine for experiments.
    spot = true
  }
}
