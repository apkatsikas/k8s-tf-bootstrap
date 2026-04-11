variable "project_id" {
  description = "GCP project ID (find it in the GCP console or via: gcloud projects list)"
  type        = string
}

variable "region" {
  description = "GCP region for Artifact Registry and general resources"
  type        = string
}

variable "zone" {
  description = "GCP zone for the GKE cluster. Single-zone is cheapest."
  type        = string
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
}

variable "domain" {
  description = "Your domain name, e.g. yourdomain.link. Used for Cloud DNS zone and the api.DOMAIN A record."
  type        = string
}

variable "email" {
  description = "Email for Let's Encrypt certificate notifications"
  type        = string
}

