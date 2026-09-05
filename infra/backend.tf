# GCS backend blocks can't use variables/interpolation, so the bucket name
# is hardcoded here — it's the bucket infra/bootstrap created.
terraform {
  backend "gcs" {
    bucket = "meridian-payments-poc-tf-state"
    prefix = "terraform/state"
  }
}
