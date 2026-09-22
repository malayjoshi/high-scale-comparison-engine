output "jobs_api_url" {
  description = "Public endpoint for submitting comparison jobs"
  value       = "${aws_api_gateway_stage.production.invoke_url}/jobs"
}

output "database_endpoint" {
  description = "Private PostgreSQL endpoint for the comparison workers"
  value       = aws_db_instance.comparison_engine.endpoint
}

output "database_master_secret_arn" {
  description = "Secrets Manager ARN containing the RDS-managed master credentials"
  value       = aws_db_instance.comparison_engine.master_user_secret[0].secret_arn
}

output "cognito_client_id" {
  description = "OAuth client ID used by the comparison application"
  value       = aws_cognito_user_pool_client.comparison_engine.id
}

output "cognito_login_url" {
  description = "Microsoft sign-in URL for the OAuth authorization-code flow"
  value       = "https://${aws_cognito_user_pool_domain.comparison_engine.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/oauth2/authorize?identity_provider=${aws_cognito_identity_provider.microsoft.provider_name}&response_type=code&client_id=${aws_cognito_user_pool_client.comparison_engine.id}&scope=openid+email+comparison-engine%2Fjobs.write&redirect_uri=${urlencode(var.oauth_callback_urls[0])}"
}

output "microsoft_saml_acs_url" {
  description = "Reply URL/ACS URL to configure in Microsoft Entra ID or AD FS"
  value       = "https://${aws_cognito_user_pool_domain.comparison_engine.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/saml2/idpresponse"
}

output "microsoft_saml_entity_id" {
  description = "Entity ID to configure in Microsoft Entra ID or AD FS"
  value       = "urn:amazon:cognito:sp:${aws_cognito_user_pool.comparison_engine.id}"
}
