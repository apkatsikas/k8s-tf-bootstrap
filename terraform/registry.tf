resource "google_artifact_registry_repository" "api" {
  location      = var.region
  repository_id = "api"
  format        = "DOCKER"

  depends_on = [google_project_service.artifactregistry]
}
