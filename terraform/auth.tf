variable "cognito_domain_prefix" {
  description = "Globally unique prefix for the Cognito managed login domain"
  type        = string
}

variable "oauth_callback_urls" {
  description = "Allowed frontend callback URLs after Cognito sign-in"
  type        = list(string)

  validation {
    condition     = length(var.oauth_callback_urls) > 0
    error_message = "At least one OAuth callback URL is required."
  }
}

variable "oauth_logout_urls" {
  description = "Allowed application URLs after sign-out"
  type        = list(string)

  validation {
    condition     = length(var.oauth_logout_urls) > 0
    error_message = "At least one OAuth logout URL is required."
  }
}

resource "aws_cognito_user_pool" "comparison_engine" {
  name                     = "comparison-engine-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  admin_create_user_config {
    # Native Cognito sign-up keeps the portfolio demo self-contained. Disable
    # this in a production tenant where users are provisioned centrally.
    allow_admin_create_user_only = false
  }

  password_policy {
    minimum_length                   = 10
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_resource_server" "comparison_engine" {
  identifier   = "comparison-engine"
  name         = "Comparison Engine"
  user_pool_id = aws_cognito_user_pool.comparison_engine.id

  scope {
    scope_name        = "jobs.write"
    scope_description = "Submit comparison jobs"
  }

  scope {
    scope_name        = "jobs.read"
    scope_description = "Read job status and results"
  }

}

resource "aws_cognito_user_pool_client" "comparison_engine" {
  name         = "comparison-engine-client"
  user_pool_id = aws_cognito_user_pool.comparison_engine.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]
  allowed_oauth_scopes = [
    "openid",
    "email",
    "${aws_cognito_resource_server.comparison_engine.identifier}/jobs.write",
    "${aws_cognito_resource_server.comparison_engine.identifier}/jobs.read"
  ]
  callback_urls                 = var.oauth_callback_urls
  logout_urls                   = var.oauth_logout_urls
  supported_identity_providers  = ["COGNITO"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 55
  id_token_validity      = 55
  refresh_token_validity = 1

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }
}

resource "aws_cognito_user_pool_domain" "comparison_engine" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.comparison_engine.id
}

resource "aws_api_gateway_authorizer" "comparison_engine" {
  name          = "comparison-engine-cognito-authorizer"
  rest_api_id   = aws_api_gateway_rest_api.comparison_engine.id
  type          = "COGNITO_USER_POOLS"
  provider_arns = [aws_cognito_user_pool.comparison_engine.arn]
}
