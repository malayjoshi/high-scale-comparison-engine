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

resource "aws_api_gateway_method" "enqueue_job" {
  rest_api_id   = aws_api_gateway_rest_api.comparison_engine.id
  resource_id   = aws_api_gateway_resource.jobs.id
  http_method   = "POST"
  authorization = "NONE"
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
    "application/json" = "Action=SendMessage&MessageBody=$util.urlEncode($input.body)"
  }
}

resource "aws_api_gateway_method_response" "accepted" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.enqueue_job.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "accepted" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id
  resource_id = aws_api_gateway_resource.jobs.id
  http_method = aws_api_gateway_method.enqueue_job.http_method
  status_code = aws_api_gateway_method_response.accepted.status_code

  depends_on = [aws_api_gateway_integration.sqs]
}

resource "aws_api_gateway_deployment" "comparison_engine" {
  rest_api_id = aws_api_gateway_rest_api.comparison_engine.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.jobs.id,
      aws_api_gateway_method.enqueue_job.id,
      aws_api_gateway_integration.sqs.id
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "production" {
  deployment_id = aws_api_gateway_deployment.comparison_engine.id
  rest_api_id   = aws_api_gateway_rest_api.comparison_engine.id
  stage_name    = "production"
}
