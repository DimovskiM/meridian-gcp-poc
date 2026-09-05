variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the state bucket"
  type        = string
  default     = "europe-west3"
}

variable "github_repository" {
  description = "owner/repo allowed to federate into this project. This is the security boundary for CI auth — only OIDC tokens from this repository can impersonate the CI service account."
  type        = string
  default     = "DimovskiM/meridian-gcp-poc"
}
