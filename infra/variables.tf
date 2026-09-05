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
  description = "Fully qualified Artifact Registry image URI (including tag) to deploy. Must already exist — built and pushed before this apply."
  type        = string
}

variable "git_commit" {
  description = "Short git SHA of the commit being deployed — surfaced in /health."
  type        = string
  default     = "unknown"
}
