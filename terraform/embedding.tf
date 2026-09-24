variable "quicksight_dashboard_id" {
  description = "Published QuickSight dashboard ID shown to registered readers"
  type        = string
  default     = "comparison-engine-dashboard"
}

variable "quicksight_embed_allowed_domains" {
  description = "Web application origins allowed to embed the QuickSight dashboard"
  type        = list(string)
  default     = ["http://localhost:3000"]

  validation {
    condition = length(var.quicksight_embed_allowed_domains) > 0 && length(var.quicksight_embed_allowed_domains) <= 3 && alltrue([
      for domain in var.quicksight_embed_allowed_domains :
      startswith(domain, "https://") || startswith(domain, "http://localhost:")
    ])
    error_message = "Supply one to three HTTPS domains; HTTP is allowed only for localhost development."
  }
}

variable "quicksight_readers" {
  description = "Registered QuickSight readers keyed by the email claim in their Cognito token"
  type = map(object({
    user_name       = string
    cognito_subject = string
  }))
  default = {}

  validation {
    condition = !var.enable_quicksight || (length(var.quicksight_readers) > 0 && alltrue([
      for email, reader in var.quicksight_readers :
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", email)) &&
      can(regex("^[A-Za-z0-9._-]{1,100}$", reader.user_name)) &&
      can(regex("^[A-Za-z0-9_-]{1,128}$", reader.cognito_subject))
    ]))
    error_message = "QuickSight readers require a valid email, user_name, and Cognito subject."
  }
}

resource "aws_quicksight_user" "reader" {
  for_each = var.enable_quicksight ? var.quicksight_readers : {}

  email         = each.key
  identity_type = "QUICKSIGHT"
  namespace     = "default"
  user_name     = each.value.user_name
  user_role     = "READER"
}

data "archive_file" "dashboard_embed" {
  type        = "zip"
  source_file = "${path.module}/../dashboard_embed/handler.py"
  output_path = "${path.module}/.build/dashboard-embed.zip"
}

resource "aws_iam_role" "dashboard_embed" {
  count = var.enable_quicksight ? 1 : 0
  name  = "comparison-engine-dashboard-embed-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "dashboard_embed" {
  count = var.enable_quicksight ? 1 : 0
  name  = "comparison-engine-dashboard-embed-policy"
  role  = aws_iam_role.dashboard_embed[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "quicksight:GenerateEmbedUrlForRegisteredUser"
        Resource = [for reader in aws_quicksight_user.reader : reader.arn]
      },
      {
        Effect   = "Allow"
        Action   = "logs:CreateLogGroup"
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/comparison-engine-dashboard-embed:*"
      }
    ]
  })
}

resource "aws_lambda_function" "dashboard_embed" {
  count         = var.enable_quicksight ? 1 : 0
  function_name = "comparison-engine-dashboard-embed"
  role          = aws_iam_role.dashboard_embed[0].arn
  runtime       = "python3.13"
  handler       = "handler.lambda_handler"
  timeout       = 10
  memory_size   = 128

  filename         = data.archive_file.dashboard_embed.output_path
  source_code_hash = data.archive_file.dashboard_embed.output_base64sha256

  environment {
    variables = {
      AWS_ACCOUNT_ID             = data.aws_caller_identity.current.account_id
      DASHBOARD_APP_ORIGIN       = var.quicksight_embed_allowed_domains[0]
      QUICKSIGHT_ALLOWED_DOMAINS = jsonencode(var.quicksight_embed_allowed_domains)
      QUICKSIGHT_DASHBOARD_ID    = var.quicksight_dashboard_id
      QUICKSIGHT_READERS         = jsonencode({ for email, reader in aws_quicksight_user.reader : lower(email) => reader.arn })
    }
  }

  depends_on = [aws_iam_role_policy.dashboard_embed]
}
