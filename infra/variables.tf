variable "project_id" {
  type = string
}

variable "region" {
  description = "EU-only per Meridian's legal requirement. Frankfurt for latency to the German customer base."
  type        = string
  default     = "europe-west3"
}

variable "vpc_cidr" {
  description = "Kept away from common AWS defaults (10.0.0.0/16, 172.31.0.0/16) so a future VPN/Interconnect to Meridian's AWS estate has room. Their real CIDR is unknown — see ASSUMPTIONS.md."
  type        = string
  default     = "10.60.0.0/16"
}

variable "app_subnet_cidr" {
  type    = string
  default = "10.60.1.0/24"
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
  description = "Stand-in for a credential Meridian would provide. Passed at apply time, never committed."
  type        = string
  sensitive   = true
}

variable "container_image" {
  description = "Only used when Terraform first creates the service and job; `gcloud run deploy` owns the image afterwards and Terraform ignores changes to it."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "reviewer_principals" {
  description = "Read-only access for the Commit review team."
  type        = list(string)
  default     = ["group:gcp-devops@comm-it.cloud"]
}
