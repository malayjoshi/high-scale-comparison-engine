variable "frontend_origin" {
  description = "Browser origin allowed to call the comparison API"
  type        = string

  validation {
    condition     = can(regex("^https?://[^/]+$", var.frontend_origin))
    error_message = "frontend_origin must be an HTTP(S) origin without a trailing slash or path."
  }
}

variable "enforce_cognito_scope" {
  description = "Require jobs.write at API Gateway. Disable only for LocalStack, whose Cognito emulator omits custom scopes from OAuth access tokens."
  type        = bool
  default     = true
}

resource "aws_api_gateway_rest_api" "comparison_engine" {
  name        = "comparison-engine-api"
  description = "WAF-protected job submission API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "jobs" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  parent_id   = aws_api_gateway_rest_api.comparison_engine.root_resource_id
  path_part   = "jobs"
}

resource "aws_api_gateway_model" "comparison_job" {
  rest_api_id  = aws_api_gateway_rest_api.comparison_engine.id
  name         = "ComparisonJobRequest"
  content_type = "application/json"
  schema = jsonencode({
    "$schema"            = "http://json-schema.org/draft-04/schema#"
    type                 = "object"
    additionalProperties = false
    required = [
      "job_id",
      "source_folder",
      "destination_folder",
      "total_expected_pairs",
      "timestamp",
      "callback_id"
    ]
    properties = {
      job_id = {
        type    = "string"
        pattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
      }
      timestamp = {
        type      = "string"
        minLength = 20
        maxLength = 40
      }
      callback_id = {
        type      = "string"
        pattern   = "^[A-Za-z0-9._-]{1,100}$"
        minLength = 1
        maxLength = 100
      }
      user_id = {
        type      = "string"
        minLength = 1
        maxLength = 128
      }
      source_folder = {
        type    = "string"
        pattern = "^[A-Za-z0-9._-]+$"
      }
      destination_folder = {
        type    = "string"
        pattern = "^[A-Za-z0-9._-]+$"
      }
      total_expected_pairs = {
        type    = "integer"
        minimum = 1
        maximum = 100
      }
    }
  })
}

resource "aws_api_gateway_request_validator" "comparison_job" {
  rest_api_id           = aws_api_gateway_rest_api.comparison_engine.id
  name                  = "comparison-job-body"
  validate_request_body = true
}

resource "aws_api_gateway_method" "enqueue_job" {
  rest_api_id          = aws_api_gateway_rest_api.comparison_engine.id
  resource_id          = aws_api_gateway_resource.jobs.id
  http_method          = "POST"
  authorization        = "COGNITO_USER_POOLS"
  authorizer_id        = aws_api_gateway_authorizer.comparison_engine.id
  request_validator_id = aws_api_gateway_request_validator.comparison_job.id

  request_models = {
    "application/json" = aws_api_gateway_model.comparison_job.name
  }

  authorization_scopes = var.enforce_cognito_scope ? [
    "${aws_cognito_resource_server.comparison_engine.identifier}/jobs.write"
  ] : []
}

resource "aws_api_gateway_integration" "sqs" {
  rest_api_id             = aws_api_gateway_rest_api.comparison_engine.id
  resource_id             = aws_api_gateway_resource.jobs.id
  http_method             = aws_api_gateway_method.enqueue_job.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  credentials             = aws_iam_role.api_gateway_sqs.arn
  uri                     = "arn:aws:apigateway:${data.aws_region.current.region}:sqs:path/${data.aws_caller_identity.current.account_id}/${aws_sqs_queue.comparison_engine_queue.name}"
  passthrough_behavior    = "NEVER"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    # Keep ingestion synchronous and small: API Gateway validates and enqueues
    # directly, while the authenticated Cognito subject becomes the user ID.
    "application/json" = var.enforce_cognito_scope ? join("\n", [
      "#set($message = $input.path('$'))",
      "$util.qr($message.put('user_id', $context.authorizer.claims.sub))",
      "Action=SendMessage&MessageBody=$util.urlEncode($util.toJson($message))"
    ]) : "Action=SendMessage&MessageBody=$util.urlEncode($input.body)"
  }
}

resource "aws_api_gateway_method_response" "accepted" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.enqueue_job.http_method
  status_code = "202"

  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_method_response" "bad_gateway_request" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.enqueue_job.http_method
  status_code = "400"

  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_method_response" "enqueue_failed" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.enqueue_job.http_method
  status_code = "500"

  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "accepted" {
  rest_api_id       = aws_api_gateway_rest_api.comparison_engine.id
  resource_id       = aws_api_gateway_resource.jobs.id
  http_method       = aws_api_gateway_method.enqueue_job.http_method
  status_code       = aws_api_gateway_method_response.accepted.status_code
  selection_pattern = "2\\d{2}"

  response_templates = {
    "application/json" = jsonencode({ status = "queued" })
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'${var.frontend_origin}'"
  }

  depends_on = [aws_api_gateway_integration.sqs]
}

resource "aws_api_gateway_integration_response" "bad_gateway_request" {
  rest_api_id       = aws_api_gateway_rest_api.comparison_engine.id
  resource_id       = aws_api_gateway_resource.jobs.id
  http_method       = aws_api_gateway_method.enqueue_job.http_method
  status_code       = aws_api_gateway_method_response.bad_gateway_request.status_code
  selection_pattern = "4\\d{2}"

  response_templates = {
    "application/json" = jsonencode({ status = "rejected" })
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'${var.frontend_origin}'"
  }

  depends_on = [aws_api_gateway_integration.sqs]
}

resource "aws_api_gateway_integration_response" "enqueue_failed" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.enqueue_job.http_method
  status_code = aws_api_gateway_method_response.enqueue_failed.status_code

  response_templates = {
    "application/json" = jsonencode({ status = "failed" })
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'${var.frontend_origin}'"
  }

  depends_on = [aws_api_gateway_integration.sqs]
}

resource "aws_api_gateway_method" "jobs_options" {
  rest_api_id   = aws_api_gateway_rest_api.comparison_engine.id
  resource_id   = aws_api_gateway_resource.jobs.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "jobs_options" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.jobs_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "jobs_options" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.jobs_options.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "jobs_options" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.jobs_options.http_method
  status_code = aws_api_gateway_method_response.jobs_options.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Authorization,Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,POST'"
    "method.response.header.Access-Control-Allow-Origin"  = "'${var.frontend_origin}'"
  }

  depends_on = [aws_api_gateway_integration.jobs_options]
}

# Lambda function for GET /jobs/{job_id}
resource "null_resource" "get_job_build" {
  triggers = {
    requirements = filemd5("${path.module}/../api_handlers/requirements.txt")
    handler      = filemd5("${path.module}/../api_handlers/get_job.py")
  }

  provisioner "local-exec" {
    command     = <<-EOT
      python3 << 'PYTHON_EOF'
      import os
      import shutil
      import subprocess
      import zipfile
      from pathlib import Path

      build_dir = Path("${path.module}/.build/get-job-tmp")
      zip_file = Path("${path.module}/.build/get-job.zip")

      # Clean and create build directory
      if build_dir.exists():
        shutil.rmtree(build_dir)
      build_dir.mkdir(parents=True, exist_ok=True)

      # Copy handler
      shutil.copy("${path.module}/../api_handlers/get_job.py", build_dir)

      # Build native wheels for Lambda's runtime instead of copying packages
      # from the developer machine's Python version.
      subprocess.run([
          "${path.module}/../scripts/.venv/bin/python", "-m", "pip", "install",
          "--platform", "manylinux2014_x86_64",
          "--implementation", "cp",
          "--python-version", "3.13",
          "--only-binary=:all:",
          "--target", str(build_dir),
          "-r", "${path.module}/../api_handlers/requirements.txt",
      ], check=True)

      # Create zip
      with zipfile.ZipFile(zip_file, 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(build_dir):
          # Skip __pycache__ and .pyc files
          dirs[:] = [d for d in dirs if d != '__pycache__']
          for file in files:
            if not file.endswith('.pyc'):
              file_path = os.path.join(root, file)
              arcname = os.path.relpath(file_path, build_dir)
              zf.write(file_path, arcname)

      print(f"Created {zip_file}")
      PYTHON_EOF
    EOT
    working_dir = path.module
  }
}

resource "aws_iam_role" "get_job_lambda" {
  name = "comparison-engine-get-job-role"

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

resource "aws_iam_role_policy" "get_job_lambda" {
  name = "comparison-engine-get-job-policy"
  role = aws_iam_role.get_job_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/comparison-engine-get-job:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_db_instance.comparison_engine.master_user_secret[0].secret_arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.comparison_results.arn}/comparison-results/*"
      }
    ]
  })
}

resource "aws_lambda_function" "get_job" {
  function_name = "comparison-engine-get-job"
  role          = aws_iam_role.get_job_lambda.arn
  runtime       = "python3.13"
  handler       = "get_job.lambda_handler"
  timeout       = 15
  memory_size   = 256

  filename = "${path.module}/.build/get-job.zip"
  source_code_hash = base64sha256(join("", [
    file("${path.module}/../api_handlers/get_job.py"),
    file("${path.module}/../api_handlers/requirements.txt")
  ]))

  # VPC configuration only for real AWS; LocalStack doesn't need it
  dynamic "vpc_config" {
    for_each = var.enforce_cognito_scope ? [1] : []
    content {
      subnet_ids         = [aws_subnet.comparison_engine_rds_1.id, aws_subnet.comparison_engine_rds_2.id]
      security_group_ids = [aws_security_group.lambda_sg.id]
    }
  }

  environment {
    variables = {
      DB_HOST         = aws_db_instance.comparison_engine.address
      DB_PORT         = aws_db_instance.comparison_engine.port
      DB_NAME         = aws_db_instance.comparison_engine.db_name
      DB_USER         = aws_db_instance.comparison_engine.username
      DB_SECRET_ARN   = aws_db_instance.comparison_engine.master_user_secret[0].secret_arn
      FRONTEND_ORIGIN = var.frontend_origin
    }
  }

  depends_on = [aws_iam_role_policy.get_job_lambda, null_resource.get_job_build]
}

resource "aws_lambda_permission" "get_job_api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_job.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.comparison_engine.execution_arn}/*/*"
}

# Security group for Lambda to access RDS
resource "aws_security_group" "lambda_sg" {
  name        = "comparison-engine-lambda-sg"
  description = "Allow Lambda functions to access RDS"
  vpc_id      = aws_vpc.comparison_engine_vpc.id

  egress {
    description     = "PostgreSQL to RDS"
    protocol        = "tcp"
    from_port       = 5432
    to_port         = 5432
    security_groups = [aws_security_group.rds.id]
  }

  egress {
    description = "DNS resolution"
    protocol    = "udp"
    from_port   = 53
    to_port     = 53
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "comparison-engine-lambda-sg"
  }
}

# API Gateway resource for /jobs/{job_id}
resource "aws_api_gateway_resource" "job_detail" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  parent_id   = aws_api_gateway_resource.jobs.id
  path_part   = "{job_id}"
}

# GET method for job status
resource "aws_api_gateway_method" "get_job" {
  rest_api_id   = aws_api_gateway_rest_api.comparison_engine.id
  resource_id   = aws_api_gateway_resource.job_detail.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.comparison_engine.id
  authorization_scopes = var.enforce_cognito_scope ? [
    "${aws_cognito_resource_server.comparison_engine.identifier}/jobs.read"
  ] : []
}

resource "aws_api_gateway_integration" "get_job" {
  rest_api_id             = aws_api_gateway_rest_api.comparison_engine.id
  resource_id             = aws_api_gateway_resource.job_detail.id
  http_method             = aws_api_gateway_method.get_job.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.get_job.invoke_arn
}

resource "aws_api_gateway_method_response" "get_job_success" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.job_detail.id
  http_method = aws_api_gateway_method.get_job.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_method_response" "get_job_not_found" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.job_detail.id
  http_method = aws_api_gateway_method.get_job.http_method
  status_code = "404"

  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_method_response" "get_job_error" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.job_detail.id
  http_method = aws_api_gateway_method.get_job.http_method
  status_code = "500"

  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "get_job_success" {
  rest_api_id       = aws_api_gateway_rest_api.comparison_engine.id
  resource_id       = aws_api_gateway_resource.job_detail.id
  http_method       = aws_api_gateway_method.get_job.http_method
  status_code       = "200"
  selection_pattern = "2\\d{2}"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'${var.frontend_origin}'"
  }

  depends_on = [aws_api_gateway_integration.get_job]
}

resource "aws_api_gateway_integration_response" "get_job_not_found" {
  rest_api_id       = aws_api_gateway_rest_api.comparison_engine.id
  resource_id       = aws_api_gateway_resource.job_detail.id
  http_method       = aws_api_gateway_method.get_job.http_method
  status_code       = "404"
  selection_pattern = "404"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'${var.frontend_origin}'"
  }

  depends_on = [aws_api_gateway_integration.get_job]
}

resource "aws_api_gateway_integration_response" "get_job_error" {
  rest_api_id       = aws_api_gateway_rest_api.comparison_engine.id
  resource_id       = aws_api_gateway_resource.job_detail.id
  http_method       = aws_api_gateway_method.get_job.http_method
  status_code       = "500"
  selection_pattern = "5\\d{2}"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'${var.frontend_origin}'"
  }

  depends_on = [aws_api_gateway_integration.get_job]
}

# OPTIONS method for CORS on /jobs/{job_id}
resource "aws_api_gateway_method" "job_detail_options" {
  rest_api_id   = aws_api_gateway_rest_api.comparison_engine.id
  resource_id   = aws_api_gateway_resource.job_detail.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "job_detail_options" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.job_detail.id
  http_method = aws_api_gateway_method.job_detail_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "job_detail_options" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.job_detail.id
  http_method = aws_api_gateway_method.job_detail_options.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "job_detail_options" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.job_detail.id
  http_method = aws_api_gateway_method.job_detail_options.http_method
  status_code = aws_api_gateway_method_response.job_detail_options.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Authorization,Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,GET'"
    "method.response.header.Access-Control-Allow-Origin"  = "'${var.frontend_origin}'"
  }

  depends_on = [aws_api_gateway_integration.job_detail_options]
}

resource "aws_api_gateway_deployment" "comparison_engine" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.jobs.id,
      aws_api_gateway_method.enqueue_job.id,
      aws_api_gateway_method.enqueue_job.authorization,
      aws_api_gateway_method.enqueue_job.authorization_scopes,
      aws_api_gateway_method.enqueue_job.request_models,
      aws_api_gateway_model.comparison_job.schema,
      aws_api_gateway_request_validator.comparison_job.id,
      aws_api_gateway_authorizer.comparison_engine.id,
      aws_api_gateway_integration.sqs.id,
      aws_api_gateway_integration.sqs.request_templates,
      aws_api_gateway_integration_response.accepted.id,
      aws_api_gateway_integration_response.bad_gateway_request.id,
      aws_api_gateway_integration_response.enqueue_failed.id,
      aws_api_gateway_method.jobs_options.id,
      aws_api_gateway_integration.jobs_options.id,
      aws_api_gateway_integration_response.jobs_options.id,
      aws_api_gateway_resource.job_detail.id,
      aws_api_gateway_method.get_job.id,
      aws_api_gateway_integration.get_job.id,
      aws_api_gateway_method.job_detail_options.id,
      aws_api_gateway_integration.job_detail_options.id,
      var.frontend_origin
    ]))
  }

  depends_on = [
    aws_api_gateway_integration_response.accepted,
    aws_api_gateway_integration_response.bad_gateway_request,
    aws_api_gateway_integration_response.enqueue_failed,
    aws_api_gateway_integration_response.jobs_options,
    aws_api_gateway_method_response.get_job_success,
    aws_api_gateway_method_response.get_job_not_found,
    aws_api_gateway_method_response.get_job_error,
    aws_api_gateway_integration_response.get_job_success,
    aws_api_gateway_integration_response.get_job_not_found,
    aws_api_gateway_integration_response.get_job_error,
    aws_api_gateway_integration_response.job_detail_options
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "production" {
  deployment_id = aws_api_gateway_deployment.comparison_engine.id
  rest_api_id   = aws_api_gateway_rest_api.comparison_engine.id
  stage_name    = "production"
}
