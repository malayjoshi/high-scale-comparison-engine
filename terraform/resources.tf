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

resource "aws_alb" "comparison_engine_alb" {
  name               = "comparison-engine-alb"
  load_balancer_type = "application"
  internal           = false
  subnets = [
    aws_subnet.comparison_engine_subnet_ec2_1.id,
    aws_subnet.comparison_engine_subnet_ec2_2.id
  ]
  security_groups = [aws_security_group.alb_sg_comparison_engine.id]

}

resource "aws_launch_template" "comparison_engine_launch_template" {
  name                   = "comparison-engine-launch-template"
  image_id               = "ami-0c55b159cbfafe1f0"
  instance_type          = "t2.micro"
  user_data              = ""
  vpc_security_group_ids = [aws_security_group.ec2_sg_comparison_engine.id]
  update_default_version = true
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
}
