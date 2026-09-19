resource "aws_wafv2_web_acl" "comparison_engine" {
  name  = "comparison-engine-api"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "RateLimitByIp"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        aggregate_key_type = "IP"
        limit              = 2000
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "comparison-engine-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "comparison-engine-common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "comparison-engine-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "comparison-engine-api"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "comparison_engine" {
  resource_arn = "arn:aws:apigateway:${data.aws_region.current.region}::/restapis/${aws_api_gateway_rest_api.comparison_engine.id}/stages/${aws_api_gateway_stage.production.stage_name}"
  web_acl_arn  = aws_wafv2_web_acl.comparison_engine.arn
}
