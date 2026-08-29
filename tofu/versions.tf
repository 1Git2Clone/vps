# OpenTofu, not HashiCorp Terraform. .terraform.lock.hcl pins providers from
# registry.opentofu.org and the `terraform` binary rewrites those to
# registry.terraform.io without asking, which is a diff nobody wants to review.
terraform {
  required_version = ">= 1.9"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.50"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# Reads HCLOUD_TOKEN from the environment when var.hcloud_token is null.
provider "hcloud" {
  token = var.hcloud_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
