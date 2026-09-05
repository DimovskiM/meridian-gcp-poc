output "app_url" {
  # App Engine's default hostname includes a region-specific subdomain that's
  # not worth hand-constructing — read it from the resource itself.
  value = "https://${google_app_engine_application.app.default_hostname}"
}

output "artifact_registry_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}"
}

output "cloudsql_private_ip" {
  value = google_sql_database_instance.postgres.private_ip_address
}
