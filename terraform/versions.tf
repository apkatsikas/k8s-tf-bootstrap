terraform {
  required_version = ">= 1.14.8"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.25"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2.4"
    }
  }
}

# TODO - where could this be moved?
provider "google" {
  project = var.project_id
  region  = var.region
}
