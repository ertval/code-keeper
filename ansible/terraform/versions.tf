terraform {
  required_version = ">= 1.5.0"

  # Partial backend configuration, as in infra/: the key lives in backend.hcl and the
  # bucket, region and lock table are passed with -backend-config, so no account
  # details are committed.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "code-keeper"
      Component = "gitlab"
      ManagedBy = "Terraform"
    }
  }
}
