variable "callback_clients" {
  description = "Authorized completion callback destinations keyed by callback_id"
  type = map(object({
    url     = string
    enabled = optional(bool, true)
  }))
  default = {}

  validation {
    condition = alltrue([
      for callback_id, client in var.callback_clients :
      can(regex("^[A-Za-z0-9._-]{1,100}$", callback_id)) &&
      can(regex("^(https://|http://(localhost|127\\.0\\.0\\.1|host\\.docker\\.internal)(:[0-9]+)?/)", client.url))
    ])
    error_message = "Callback IDs must be valid identifiers; URLs must use HTTPS or an explicitly local HTTP host."
  }
}

resource "aws_dynamodb_table" "callback_clients" {
  name         = "comparison-engine-callback-clients"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "callback_id"

  attribute {
    name = "callback_id"
    type = "S"
  }
}

resource "aws_dynamodb_table_item" "callback_clients" {
  for_each = var.callback_clients

  table_name = aws_dynamodb_table.callback_clients.name
  hash_key   = aws_dynamodb_table.callback_clients.hash_key
  item = jsonencode({
    callback_id  = { S = each.key }
    callback_url = { S = each.value.url }
    enabled      = { BOOL = each.value.enabled }
  })
}

data "archive_file" "callback" {
  type        = "zip"
  source_file = "${path.module}/../callback/handler.py"
  output_path = "${path.module}/.build/comparison-callback.zip"
}

resource "aws_iam_role" "callback" {
  name = "comparison-engine-callback-role"

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

resource "aws_iam_role_policy" "callback" {
  name = "comparison-engine-callback-policy"
  role = aws_iam_role.callback.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.comparison_completion.arn
      },
      {
        Effect   = "Allow"
        Action   = "dynamodb:GetItem"
        Resource = aws_dynamodb_table.callback_clients.arn
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
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/comparison-engine-callback:*"
      }
    ]
  })
}

resource "aws_lambda_function" "callback" {
  function_name = "comparison-engine-callback"
  role          = aws_iam_role.callback.arn
  runtime       = "python3.13"
  handler       = "handler.lambda_handler"
  timeout       = 15
  memory_size   = 128

  filename         = data.archive_file.callback.output_path
  source_code_hash = data.archive_file.callback.output_base64sha256

  environment {
    variables = {
      CALLBACK_CLIENTS_TABLE = aws_dynamodb_table.callback_clients.name
    }
  }

  depends_on = [aws_iam_role_policy.callback]
}

resource "aws_lambda_event_source_mapping" "callback" {
  event_source_arn = aws_sqs_queue.comparison_completion.arn
  function_name    = aws_lambda_function.callback.arn
  batch_size       = 10

  function_response_types = ["ReportBatchItemFailures"]
}
