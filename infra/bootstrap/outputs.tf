output "state_bucket_name" {
  value = google_storage_bucket.tf_state.name
}

output "ci_service_account_email" {
  value = google_service_account.ci.email
}

# Base64-encoded JSON key material. Never printed to a log or committed —
# extracted once locally via `terraform output -raw ci_key_json | base64 -d`
# and pushed straight into a GitHub Actions secret.
output "ci_key_json" {
  value     = google_service_account_key.ci_key.private_key
  sensitive = true
}
