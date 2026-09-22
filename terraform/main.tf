terraform {
  required_providers {
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

provider "aws" {
  region = var.aws_region
}
