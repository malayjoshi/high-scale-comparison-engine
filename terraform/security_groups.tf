resource "aws_security_group" "ec2_sg_comparison_engine" {
  name        = "ec2-sg-comparison-engine"
  description = "Security group for the comparison engine workers"
  vpc_id      = aws_vpc.comparison_engine_vpc.id

  egress {
    description = "HTTPS to VPC interface endpoints"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = [aws_vpc.comparison_engine_vpc.cidr_block]
  }

  egress {
    description = "PostgreSQL to private RDS subnets"
    protocol    = "tcp"
    from_port   = 5432
    to_port     = 5432
    cidr_blocks = [
      aws_subnet.comparison_engine_rds_1.cidr_block,
      aws_subnet.comparison_engine_rds_2.cidr_block
    ]
  }
}

resource "aws_security_group" "sqs_endpoint" {
  name        = "comparison-engine-sqs-endpoint-sg"
  description = "Allow HTTPS from comparison workers"
  vpc_id      = aws_vpc.comparison_engine_vpc.id

  ingress {
    description     = "HTTPS from comparison workers"
    protocol        = "tcp"
    from_port       = 443
    to_port         = 443
    security_groups = [aws_security_group.ec2_sg_comparison_engine.id]
  }
}

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = aws_vpc.comparison_engine_vpc.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.sqs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids = [
    aws_subnet.comparison_engine_subnet_ec2_1.id,
    aws_subnet.comparison_engine_subnet_ec2_2.id
  ]

  security_group_ids = [aws_security_group.sqs_endpoint.id]

  tags = {
    Name = "comparison-engine-sqs-endpoint"
  }
}
