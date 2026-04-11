output "cluster_name" {
  value = google_container_cluster.main.name
}

output "registry_url" {
  description = "Artifact Registry base URL — pass as REGISTRY= in make commands"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.api.repository_id}"
}

output "configure_kubectl" {
  description = "Run this once to point kubectl at your GKE cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --zone ${var.zone} --project ${var.project_id}"
}

output "configure_docker" {
  description = "Run this once to authenticate Docker with Artifact Registry"
  value       = "gcloud auth configure-docker ${var.region}-docker.pkg.dev"
}

output "hostname" {
  value = "api.${var.domain}"
}

output "le_email" {
  value     = var.email
  sensitive = true
}

output "dns_zone_name" {
  value = google_dns_managed_zone.main.name
}

output "external_dns_sa_email" {
  description = "GCP service account email for external-dns Workload Identity"
  value       = google_service_account.external_dns.email
}

