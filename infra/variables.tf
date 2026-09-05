variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region — EU-only per Meridian's legal requirement (payment data). Frankfurt: EU, good latency for the German customer base and reasonable for Lithuania."
  type        = string
  default     = "europe-west3"
}

variable "vpc_cidr" {
  description = "Custom VPC CIDR. Deliberately away from common AWS defaults (10.0.0.0/16, 172.31.0.0/16) to reduce collision odds with Meridian's real AWS CIDR ahead of any future VPN/Interconnect — unverified, flagged in ASSUMPTIONS.md."
  type        = string
  default     = "10.60.0.0/16"
}

variable "app_subnet_cidr" {
  description = "Subnet for the App Engine flexible instances."
  type        = string
  default     = "10.60.1.0/24"
}

variable "db_name" {
  type    = string
  default = "meridian"
}

variable "db_user" {
  type    = string
  default = "meridian_app"
}

variable "third_party_api_token" {
  description = "Stand-in for a real credential Meridian would provide for their third-party provider. Supplied at apply time (TF_VAR_third_party_api_token), never committed."
  type        = string
  sensitive   = true
}

variable "container_image" {
  description = "Image used only when Terraform first creates the service and job — after that, `gcloud run deploy` owns the image and Terraform ignores changes to it (see cloudrun.tf). Defaults to Google's hello container so a from-scratch `terraform apply` works before any app image has been built."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}
