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
    # Keep ingestion synchronous and small: API Gateway validates and enqueues
    # directly, while the authenticated Cognito subject becomes the user ID.
    "application/json" = <<-VTL
      #set($message = "{\"job_id\":\"$util.escapeJavaScript($input.path('$.job_id'))\",\"source_folder\":\"$util.escapeJavaScript($input.path('$.source_folder'))\",\"destination_folder\":\"$util.escapeJavaScript($input.path('$.destination_folder'))\",\"total_expected_pairs\":$input.path('$.total_expected_pairs'),\"timestamp\":\"$util.escapeJavaScript($input.path('$.timestamp'))\",\"callback_id\":\"$util.escapeJavaScript($input.path('$.callback_id'))\",\"user_id\":\"$util.escapeJavaScript($context.authorizer.claims.sub)\"}")Action=SendMessage&MessageBody=$util.urlEncode($message)
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

resource "aws_api_gateway_method_response" "bad_gateway_request" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.enqueue_job.http_method
  status_code = "400"

  response_models = {
    "application/json" = "Empty"
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

  depends_on = [aws_api_gateway_integration.sqs]
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
      aws_api_gateway_integration_response.enqueue_failed.id
    ]))
  }

  depends_on = [
    aws_api_gateway_integration_response.accepted,
    aws_api_gateway_integration_response.bad_gateway_request,
    aws_api_gateway_integration_response.enqueue_failed
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
