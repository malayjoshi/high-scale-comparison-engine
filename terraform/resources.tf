resource "aws_vpc" "comparison_engine_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "comparison-engine-vpc"
  }
}

resource "aws_subnet" "comparison_engine_subnet_ec2_1" {
  vpc_id            = aws_vpc.comparison_engine_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "eu-west-1a"
}

resource "aws_subnet" "comparison_engine_subnet_ec2_2" {
  vpc_id            = aws_vpc.comparison_engine_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-west-1b"
}

resource "aws_launch_template" "comparison_engine_launch_template" {
  name          = "comparison-engine-launch-template"
  image_id      = local.worker_ami_id
  instance_type = "t2.micro"
  user_data = base64encode(templatefile("${path.module}/worker-user-data.sh.tftpl", {
    aws_region          = data.aws_region.current.region
    database_endpoint   = aws_db_instance.comparison_engine.endpoint
    database_name       = aws_db_instance.comparison_engine.db_name
    database_secret_arn = aws_db_instance.comparison_engine.master_user_secret[0].secret_arn
    dummy_data_version  = var.dummy_data_version
    efs_id              = aws_efs_file_system.comparison_data.id
    queue_url           = aws_sqs_queue.comparison_engine_queue.url
    results_bucket      = aws_s3_bucket.comparison_results.id
    seed_bucket         = aws_s3_bucket.dummy_data.id
  }))
  vpc_security_group_ids = [aws_security_group.ec2_sg_comparison_engine.id]
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.comparison_worker.name
  }
}

resource "aws_autoscaling_group" "comparison_engine_asg" {
  name             = "comparison-engine-asg"
  min_size         = 3
  max_size         = 10
  desired_capacity = 5
  vpc_zone_identifier = [
    aws_subnet.comparison_engine_subnet_ec2_1.id,
    aws_subnet.comparison_engine_subnet_ec2_2.id
  ]
  health_check_type = "EC2"
  launch_template {
    id      = aws_launch_template.comparison_engine_launch_template.id
    version = "$Latest"
  }

  depends_on = [
    aws_efs_mount_target.worker_1,
    aws_efs_mount_target.worker_2,
    aws_iam_role_policy.comparison_worker_database_secret,
    aws_iam_role_policy.comparison_worker_results,
    aws_iam_role_policy.comparison_worker_seed_data,
    aws_iam_role_policy.comparison_worker_sqs,
    aws_vpc_endpoint.s3,
    terraform_data.dummy_data_archive
  ]
}

resource "aws_sqs_queue" "comparison_engine_dlq" {
  name                      = "comparison-engine-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "comparison_engine_queue" {
  name                       = "comparison-engine-queue"
  visibility_timeout_seconds = 900

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.comparison_engine_dlq.arn
    maxReceiveCount     = 5
  })
}
