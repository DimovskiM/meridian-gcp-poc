resource "google_artifact_registry_repository" "app" {
  project       = var.project_id
  location      = var.region
  repository_id = "meridian-app"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}
