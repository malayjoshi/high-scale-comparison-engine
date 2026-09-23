packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.2"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "subnet_id" {
  type    = string
  default = null
}

locals {
  build_timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "amazon-ebs" "comparison_worker" {
  region        = var.aws_region
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  ssh_username  = "ec2-user"

  associate_public_ip_address = true
  ami_name                    = "comparison-engine-worker-${local.build_timestamp}"

  source_ami_filter {
    filters = {
      architecture        = "x86_64"
      name                = "al2023-ami-2023.*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  tags = {
    Name        = "comparison-engine-worker-${local.build_timestamp}"
    Application = "comparison-engine"
    Component   = "worker"
    ManagedBy   = "packer"
  }

  run_tags = {
    Name        = "comparison-engine-worker-ami-builder"
    Application = "comparison-engine"
    ManagedBy   = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.comparison_worker"]

  provisioner "file" {
    source      = "scripts/src"
    destination = "/tmp/"
  }

  provisioner "file" {
    source      = "scripts/requirements.txt"
    destination = "/tmp/requirements.txt"
  }

  provisioner "file" {
    source      = "scripts/comparison-worker.service"
    destination = "/tmp/comparison-worker.service"
  }

  provisioner "shell" {
    script = "packer/install-worker.sh"
  }
}
