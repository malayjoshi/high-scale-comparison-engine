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
