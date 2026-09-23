variable "dummy_data_version" {
  description = "Bump this value to upload and seed a new dummy_data archive"
  type        = string
  default     = "20260923"
}

resource "aws_efs_file_system" "comparison_data" {
  creation_token = "comparison-engine-data"
  encrypted      = true

  tags = {
    Name = "comparison-engine-data"
  }
}

resource "aws_efs_mount_target" "worker_1" {
  file_system_id  = aws_efs_file_system.comparison_data.id
  subnet_id       = aws_subnet.comparison_engine_subnet_ec2_1.id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_mount_target" "worker_2" {
  file_system_id  = aws_efs_file_system.comparison_data.id
  subnet_id       = aws_subnet.comparison_engine_subnet_ec2_2.id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_s3_bucket" "dummy_data" {
  bucket        = "comparison-engine-data-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "dummy_data" {
  bucket = aws_s3_bucket.dummy_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "comparison_results" {
  bucket        = "comparison-engine-results-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "comparison_results" {
  bucket = aws_s3_bucket.comparison_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "comparison_results" {
  bucket = aws_s3_bucket.comparison_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "comparison_results_tls" {
  bucket = aws_s3_bucket.comparison_results.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.comparison_results.arn,
        "${aws_s3_bucket.comparison_results.arn}/*"
      ]
      Condition = {
        Bool = {
          "aws:SecureTransport" = "false"
        }
      }
    }]
  })
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.comparison_engine_vpc.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_vpc.comparison_engine_vpc.main_route_table_id]

  tags = {
    Name = "comparison-engine-s3-endpoint"
  }
}

# EFS cannot ingest a local directory directly. Stage one compressed archive in
# S3 so a private worker can initialize the shared filesystem without a NAT.
resource "terraform_data" "dummy_data_archive" {
  triggers_replace = [var.dummy_data_version]

  provisioner "local-exec" {
    working_dir = path.module
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      test -d ../dummy_data
      tar -C .. -czf - dummy_data | aws s3 cp - s3://${aws_s3_bucket.dummy_data.id}/dummy_data.tar.gz
    EOT
  }

  depends_on = [aws_s3_bucket_public_access_block.dummy_data]
}
