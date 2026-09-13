resource "aws_security_group" "alb_sg_comparison_engine" {
  name        = "alb-sg-comparison-engine"
  description = "Security group for the comparison engine ALB"
  vpc_id      = aws_vpc.comparison_engine_vpc.id
  ingress = [{
    description      = "Allow HTTPS traffic from the internet"
    from_port        = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    self             = false
    to_port          = 443
    ipv6_cidr_blocks = ["::/0"]
    prefix_list_ids  = []
    security_groups  = []
  }]
}

resource "aws_security_group" "ec2_sg_comparison_engine" {
  name        = "ec2-sg-comparison-engine"
  description = "Security group for the comparison engine EC2 instances"
  vpc_id      = aws_vpc.comparison_engine_vpc.id
  ingress = [{
    description = "Allow HTTPS traffic from the ALB"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    security_groups = [
      aws_security_group.alb_sg_comparison_engine.id
    ]
    prefix_list_ids  = []
    self             = false
    cidr_blocks      = []
    ipv6_cidr_blocks = []
  }]

}
