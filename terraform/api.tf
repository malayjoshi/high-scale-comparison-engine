data "aws_caller_identity" "current" {}

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
    required             = ["job_id", "folder", "timestamp", "callback_id"]
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
      folder = {
        type     = "array"
        minItems = 1
        maxItems = 100
        items = {
          type                 = "object"
          additionalProperties = false
          required             = ["source_folder", "destination_folder"]
          properties = {
            source_folder = {
              type    = "string"
              pattern = "^[A-Za-z0-9._-]+$"
            }
            destination_folder = {
              type    = "string"
              pattern = "^[A-Za-z0-9._-]+$"
            }
          }
        }
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

  authorization_scopes = [
    "${aws_cognito_resource_server.comparison_engine.identifier}/jobs.write"
  ]
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
    "application/json" = <<-VTL
      #set($message = "{\"job_id\":\"$util.escapeJavaScript($input.path('$.job_id'))\",\"folder\":$input.json('$.folder'),\"timestamp\":\"$util.escapeJavaScript($input.path('$.timestamp'))\",\"callback_id\":\"$util.escapeJavaScript($input.path('$.callback_id'))\",\"user_id\":\"$util.escapeJavaScript($context.authorizer.claims.sub)\"}")Action=SendMessage&MessageBody=$util.urlEncode($message)
    VTL
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
}

resource "aws_api_gateway_integration_response" "accepted" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.enqueue_job.http_method
  status_code = aws_api_gateway_method_response.accepted.status_code

  response_templates = {
    "application/json" = jsonencode({ status = "queued" })
  }

  depends_on = [aws_api_gateway_integration.sqs]
}

resource "aws_api_gateway_resource" "dashboard" {
  count       = var.enable_quicksight ? 1 : 0
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  parent_id   = aws_api_gateway_rest_api.comparison_engine.root_resource_id
  path_part   = "dashboard"
}

resource "aws_api_gateway_resource" "dashboard_embed_url" {
  count       = var.enable_quicksight ? 1 : 0
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  parent_id   = aws_api_gateway_resource.dashboard[0].id
  path_part   = "embed-url"
}

resource "aws_api_gateway_method" "dashboard_embed_url" {
  count         = var.enable_quicksight ? 1 : 0
  rest_api_id   = aws_api_gateway_rest_api.comparison_engine.id
  resource_id   = aws_api_gateway_resource.dashboard_embed_url[0].id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.comparison_engine.id

  authorization_scopes = [
    "${aws_cognito_resource_server.comparison_engine.identifier}/dashboard.read"
  ]
}

resource "aws_api_gateway_integration" "dashboard_embed_url" {
  count                   = var.enable_quicksight ? 1 : 0
  rest_api_id             = aws_api_gateway_rest_api.comparison_engine.id
  resource_id             = aws_api_gateway_resource.dashboard_embed_url[0].id
  http_method             = aws_api_gateway_method.dashboard_embed_url[0].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.dashboard_embed[0].invoke_arn
}

resource "aws_lambda_permission" "dashboard_embed_api" {
  count         = var.enable_quicksight ? 1 : 0
  statement_id  = "AllowApiGatewayDashboardEmbed"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dashboard_embed[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.comparison_engine.execution_arn}/*/GET/dashboard/embed-url"
}

resource "aws_api_gateway_method" "dashboard_embed_options" {
  count         = var.enable_quicksight ? 1 : 0
  rest_api_id   = aws_api_gateway_rest_api.comparison_engine.id
  resource_id   = aws_api_gateway_resource.dashboard_embed_url[0].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "dashboard_embed_options" {
  count       = var.enable_quicksight ? 1 : 0
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.dashboard_embed_url[0].id
  http_method = aws_api_gateway_method.dashboard_embed_options[0].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "dashboard_embed_options" {
  count       = var.enable_quicksight ? 1 : 0
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.dashboard_embed_url[0].id
  http_method = aws_api_gateway_method.dashboard_embed_options[0].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "dashboard_embed_options" {
  count       = var.enable_quicksight ? 1 : 0
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.dashboard_embed_url[0].id
  http_method = aws_api_gateway_method.dashboard_embed_options[0].http_method
  status_code = aws_api_gateway_method_response.dashboard_embed_options[0].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Authorization,Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'${var.quicksight_embed_allowed_domains[0]}'"
  }

  depends_on = [aws_api_gateway_integration.dashboard_embed_options]
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
      aws_api_gateway_resource.dashboard[*].id,
      aws_api_gateway_resource.dashboard_embed_url[*].id,
      aws_api_gateway_method.dashboard_embed_url[*].id,
      aws_api_gateway_integration.dashboard_embed_url[*].id,
      aws_api_gateway_method.dashboard_embed_options[*].id,
      aws_api_gateway_integration.dashboard_embed_options[*].id,
      aws_api_gateway_integration_response.dashboard_embed_options[*].id
    ]))
  }

  depends_on = [
    aws_api_gateway_integration.sqs,
    aws_api_gateway_integration.dashboard_embed_url,
    aws_api_gateway_integration.dashboard_embed_options
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
