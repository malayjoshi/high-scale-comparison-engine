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

output "cognito_user_pool_id" {
  description = "Native Cognito user pool used by the demo frontend"
  value       = aws_cognito_user_pool.comparison_engine.id
}

output "cognito_domain_url" {
  description = "Base URL of the Cognito managed login domain"
  value       = "https://${aws_cognito_user_pool_domain.comparison_engine.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}

output "cognito_login_url" {
  description = "Native Cognito sign-in URL for the OAuth authorization-code flow"
  value       = "https://${aws_cognito_user_pool_domain.comparison_engine.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/oauth2/authorize?response_type=code&client_id=${aws_cognito_user_pool_client.comparison_engine.id}&scope=openid+email+comparison-engine%2Fjobs.write+comparison-engine%2Fjobs.read&redirect_uri=${urlencode(var.oauth_callback_urls[0])}"
}

output "cognito_logout_url" {
  description = "Cognito endpoint that clears the managed-login session"
  value       = "https://${aws_cognito_user_pool_domain.comparison_engine.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/logout?client_id=${aws_cognito_user_pool_client.comparison_engine.id}&logout_uri=${urlencode(var.oauth_logout_urls[0])}"
}
