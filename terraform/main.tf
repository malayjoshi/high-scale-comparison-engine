terraform {
  required_providers {
    archive = {
      source = "hashicorp/archive"
    }
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "aws_region" {
  description = "AWS region for the comparison engine"
  type        = string
  default     = "eu-west-1"
}

variable "worker_ami_id" {
  description = "Explicit worker AMI override; null selects the latest Packer-built worker image"
  type        = string
  default     = null

  validation {
    condition     = var.worker_ami_id == null || startswith(var.worker_ami_id, "ami-")
    error_message = "worker_ami_id must be null or an AMI ID beginning with ami-."
  }
}

data "aws_ami" "comparison_worker" {
  count       = var.worker_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "tag:Application"
    values = ["comparison-engine"]
  }

  filter {
    name   = "tag:Component"
    values = ["worker"]
  }

  filter {
    name   = "tag:ManagedBy"
    values = ["packer"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  worker_ami_id = var.worker_ami_id != null ? var.worker_ami_id : data.aws_ami.comparison_worker[0].id
}

provider "aws" {
  region = var.aws_region
}
