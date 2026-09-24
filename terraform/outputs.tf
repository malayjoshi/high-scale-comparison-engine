output "jobs_api_url" {
  description = "Public endpoint for submitting comparison jobs"
  value       = "${aws_api_gateway_stage.production.invoke_url}/jobs"
}

output "comparison_queue_url" {
  description = "SQS queue polled by comparison workers"
  value       = aws_sqs_queue.comparison_engine_queue.url
}

output "comparison_results_bucket" {
  description = "Private S3 bucket containing folder-pair comparison JSON"
  value       = aws_s3_bucket.comparison_results.id
}

output "glue_comparison_results_table" {
  description = "Glue Data Catalog table queried by Athena"
  value       = "${aws_glue_catalog_database.comparison_engine.name}.${aws_glue_catalog_table.comparison_results.name}"
}

output "athena_analytics_workgroup" {
  description = "Athena workgroup used for comparison analytics"
  value       = aws_athena_workgroup.comparison_analytics.name
}

output "quicksight_comparison_dataset_arn" {
  description = "QuickSight SPICE dataset ARN when QuickSight is enabled"
  value       = var.enable_quicksight ? aws_quicksight_data_set.comparison_results[0].arn : null
}

output "dashboard_embed_url_endpoint" {
  description = "JWT-protected endpoint that creates registered-reader embed URLs"
  value       = var.enable_quicksight ? "${aws_api_gateway_stage.production.invoke_url}/dashboard/embed-url" : null
}

output "worker_ami_id" {
  description = "AMI selected for the comparison worker launch template"
  value       = local.worker_ami_id
}

output "comparison_completion_queue_url" {
  description = "SQS queue receiving transactional-outbox completion events"
  value       = aws_sqs_queue.comparison_completion.url
}

output "callback_clients_table_name" {
  description = "DynamoDB table containing authorized callback destinations"
  value       = aws_dynamodb_table.callback_clients.name
}

output "database_endpoint" {
  description = "Private PostgreSQL endpoint for the comparison workers"
  value       = aws_db_instance.comparison_engine.endpoint
}

output "database_master_secret_arn" {
  description = "Secrets Manager ARN containing the RDS-managed master credentials"
  value       = aws_db_instance.comparison_engine.master_user_secret[0].secret_arn
}

output "efs_file_system_id" {
  description = "Shared filesystem mounted by comparison workers"
  value       = aws_efs_file_system.comparison_data.id
}

output "worker_dummy_data_path" {
  description = "Path containing the shared generated input data on every worker"
  value       = "/mnt/comparison-engine/dummy_data"
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
