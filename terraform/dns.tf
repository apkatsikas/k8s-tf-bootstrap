# Cloud DNS managed zone for your domain.
# DNS records are managed by external-dns running in the cluster — no A records
# are declared here. The zone itself must still exist as a Terraform resource
# so external-dns has a zone to write into.
resource "google_dns_managed_zone" "main" {
  name     = replace(var.domain, ".", "-")
  dns_name = "${var.domain}."

  depends_on = [google_project_service.dns]

  lifecycle {
    prevent_destroy = true
  }
}

# Point the domain registration's nameservers at the Cloud DNS zone.
# Runs automatically on apply; re-runs only if the zone nameservers change.
resource "null_resource" "sync_nameservers" {
  triggers = {
    name_servers = join(",", google_dns_managed_zone.main.name_servers)
  }

  depends_on = [google_project_service.domains]

  provisioner "local-exec" {
    command = <<-EOT
      gcloud domains registrations configure dns ${var.domain} \
        --cloud-dns-zone=${google_dns_managed_zone.main.name} \
        --project=${var.project_id} \
        --quiet
    EOT
  }
}
