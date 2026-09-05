output "app_url" {
  # App Engine's default hostname includes a region-specific subdomain that's
  # not worth hand-constructing — read it from the resource itself. This is
  # the one output actually needed: it's the submission's required Live URL.
  value = "https://${google_app_engine_application.app.default_hostname}"
}
