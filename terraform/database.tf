resource "aws_subnet" "comparison_engine_rds_1" {
  vpc_id                  = aws_vpc.comparison_engine_vpc.id
  cidr_block              = "10.0.11.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = false

  tags = {
    Name = "comparison-engine-rds-eu-west-1a"
    Tier = "data"
  }
}

resource "aws_subnet" "comparison_engine_rds_2" {
  vpc_id                  = aws_vpc.comparison_engine_vpc.id
  cidr_block              = "10.0.12.0/24"
  availability_zone       = "eu-west-1b"
  map_public_ip_on_launch = false

  tags = {
    Name = "comparison-engine-rds-eu-west-1b"
    Tier = "data"
  }
}

resource "aws_db_subnet_group" "comparison_engine" {
  name        = "comparison-engine-rds"
  description = "Private subnets for the comparison engine RDS deployment"
  subnet_ids = [
    aws_subnet.comparison_engine_rds_1.id,
    aws_subnet.comparison_engine_rds_2.id
  ]

  tags = {
    Name = "comparison-engine-rds"
  }
}

resource "aws_security_group" "rds" {
  name        = "comparison-engine-rds-sg"
  description = "Allow PostgreSQL connections from comparison workers"
  vpc_id      = aws_vpc.comparison_engine_vpc.id

  ingress {
    description     = "PostgreSQL from worker ASG"
    protocol        = "tcp"
    from_port       = 5432
    to_port         = 5432
    security_groups = [aws_security_group.ec2_sg_comparison_engine.id]
  }

  tags = {
    Name = "comparison-engine-rds-sg"
  }
}

resource "aws_db_instance" "comparison_engine" {
  identifier = "comparison-engine-postgres"

  engine         = "postgres"
  instance_class = "db.t4g.micro"
  db_name        = "comparison_engine"
  username       = "comparison_admin"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  multi_az               = true
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.comparison_engine.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  manage_master_user_password = true
  backup_retention_period     = 7
  auto_minor_version_upgrade  = true
  copy_tags_to_snapshot       = true

  deletion_protection = false
  skip_final_snapshot = true

  tags = {
    Name        = "comparison-engine-postgres"
    Application = "comparison-engine"
    Component   = "database"
    ManagedBy   = "terraform"
  }
}
