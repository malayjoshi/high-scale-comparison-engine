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

variable "s3_use_path_style" {
  description = "Use path-style S3 requests for LocalStack compatibility"
  type        = bool
  default     = false
}

variable "autoscaling_policies_enabled" {
  description = "Enable worker scaling policies; LocalStack records these policies as disabled"
  type        = bool
  default     = true
}

variable "database_max_allocated_storage" {
  description = "Maximum RDS autoscaled storage in GiB; use zero where storage autoscaling is not emulated"
  type        = number
  default     = 100

  validation {
    condition     = var.database_max_allocated_storage == 0 || var.database_max_allocated_storage >= 20
    error_message = "database_max_allocated_storage must be zero or at least 20 GiB."
  }
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
  region            = var.aws_region
  s3_use_path_style = var.s3_use_path_style
}
