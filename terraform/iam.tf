resource "aws_iam_role" "api_gateway_sqs" {
  name = "comparison-engine-api-gateway-sqs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "api_gateway_sqs" {
  name = "comparison-engine-api-gateway-sqs-policy"
  role = aws_iam_role.api_gateway_sqs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.comparison_engine_queue.arn
    }]
  })
}

resource "aws_iam_role" "comparison_worker" {
  name = "comparison-engine-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "comparison_worker_sqs" {
  name = "comparison-engine-worker-sqs-policy"
  role = aws_iam_role.comparison_worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl"
      ]
      Resource = aws_sqs_queue.comparison_engine_queue.arn
    }]
  })
}

resource "aws_iam_role_policy" "comparison_worker_database_secret" {
  name = "comparison-engine-worker-database-secret-policy"
  role = aws_iam_role.comparison_worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_db_instance.comparison_engine.master_user_secret[0].secret_arn
    }]
  })
}

resource "aws_iam_instance_profile" "comparison_worker" {
  name = "comparison-engine-worker-profile"
  role = aws_iam_role.comparison_worker.name
}
