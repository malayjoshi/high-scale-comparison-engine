variable "microsoft_saml_metadata_url" {
  description = "HTTPS metadata URL published by Microsoft Entra ID or AD FS"
  type        = string

  validation {
    condition     = startswith(var.microsoft_saml_metadata_url, "https://")
    error_message = "The Microsoft SAML metadata URL must use HTTPS."
  }
}

variable "cognito_domain_prefix" {
  description = "Globally unique prefix for the Cognito managed login domain"
  type        = string
}

variable "oauth_callback_urls" {
  description = "Allowed application callback URLs after Microsoft sign-in"
  type        = list(string)

  validation {
    condition     = length(var.oauth_callback_urls) > 0
    error_message = "At least one OAuth callback URL is required."
  }
}

variable "oauth_logout_urls" {
  description = "Allowed application URLs after sign-out"
  type        = list(string)
  default     = []
}

resource "aws_cognito_user_pool" "comparison_engine" {
  name                = "comparison-engine-users"
  username_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = true
  }
}

resource "aws_cognito_identity_provider" "microsoft" {
  user_pool_id  = aws_cognito_user_pool.comparison_engine.id
  provider_name = "Microsoft"
  provider_type = "SAML"

  provider_details = {
    MetadataURL = var.microsoft_saml_metadata_url
  }

  attribute_mapping = {
    email = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"
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
    scope_name        = "dashboard.read"
    scope_description = "View comparison dashboards"
  }
}

resource "aws_cognito_user_pool_client" "comparison_engine" {
  name         = "comparison-engine-client"
  user_pool_id = aws_cognito_user_pool.comparison_engine.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
  allowed_oauth_scopes = [
    "openid",
    "email",
    "${aws_cognito_resource_server.comparison_engine.identifier}/jobs.write",
    "${aws_cognito_resource_server.comparison_engine.identifier}/dashboard.read"
  ]
  callback_urls                 = var.oauth_callback_urls
  logout_urls                   = var.oauth_logout_urls
  supported_identity_providers  = [aws_cognito_identity_provider.microsoft.provider_name]
  prevent_user_existence_errors = "ENABLED"

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
