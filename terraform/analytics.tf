variable "enable_quicksight" {
  description = "Create the QuickSight Athena data source and SPICE dataset"
  type        = bool
  default     = false
}

variable "quicksight_principal_arn" {
  description = "QuickSight user or group ARN allowed to manage the analytics dataset"
  type        = string
  default     = null

  validation {
    condition     = !var.enable_quicksight || (var.quicksight_principal_arn != null && startswith(var.quicksight_principal_arn, "arn:aws:quicksight:"))
    error_message = "quicksight_principal_arn must be supplied when enable_quicksight is true."
  }
}

locals {
  quicksight_columns = [
    { name = "job_id", type = "STRING" },
    { name = "user_id", type = "STRING" },
    { name = "request_timestamp", type = "DATETIME" },
    { name = "comparison_completed_at", type = "DATETIME" },
    { name = "completion_date", type = "DATETIME" },
    { name = "source_folder", type = "STRING" },
    { name = "destination_folder", type = "STRING" },
    { name = "common_file_count", type = "INTEGER" },
    { name = "added_file_count", type = "INTEGER" },
    { name = "deleted_file_count", type = "INTEGER" },
    { name = "filename", type = "STRING" },
    { name = "primary_key_column", type = "STRING" },
    { name = "matching_column_count", type = "INTEGER" },
    { name = "added_column_count", type = "INTEGER" },
    { name = "deleted_column_count", type = "INTEGER" },
    { name = "matching_primary_key_count", type = "INTEGER" },
    { name = "added_row_count", type = "INTEGER" },
    { name = "deleted_row_count", type = "INTEGER" },
    { name = "cell_mismatch_count", type = "INTEGER" }
  ]

  comparison_dashboard_sql = <<-SQL
    SELECT
      results.job_id,
      results.user_id,
      from_iso8601_timestamp(results.request_timestamp) AS request_timestamp,
      from_iso8601_timestamp(results.comparison_completed_at) AS comparison_completed_at,
      CAST(results.completion_date AS date) AS completion_date,
      results.source_folder,
      results.destination_folder,
      cardinality(results.files.common) AS common_file_count,
      cardinality(results.files.added) AS added_file_count,
      cardinality(results.files.deleted) AS deleted_file_count,
      comparison.filename,
      comparison.primary_key_column,
      cardinality(comparison.columns.matching) AS matching_column_count,
      cardinality(comparison.columns.added) AS added_column_count,
      cardinality(comparison.columns.deleted) AS deleted_column_count,
      comparison.rows.matching_primary_key_count,
      cardinality(comparison.rows.added_primary_keys) AS added_row_count,
      cardinality(comparison.rows.deleted_primary_keys) AS deleted_row_count,
      cardinality(comparison.rows.cell_mismatches) AS cell_mismatch_count
    FROM "${aws_glue_catalog_database.comparison_engine.name}"."${aws_glue_catalog_table.comparison_results.name}" AS results
    LEFT JOIN UNNEST(results.file_comparisons) AS compared (comparison) ON TRUE
  SQL

  quicksight_rls_sql = "SELECT * FROM (VALUES ${join(",", [for reader in var.quicksight_readers : "('${reader.user_name}','${reader.cognito_subject}')"])}) AS rules (UserName, user_id)"
}

resource "aws_athena_workgroup" "comparison_analytics" {
  name = "comparison-engine-analytics"

  configuration {
    bytes_scanned_cutoff_per_query     = 1073741824
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.comparison_results.id}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

resource "aws_athena_named_query" "comparison_dashboard" {
  name        = "comparison-dashboard-flat-results"
  description = "Flattened comparison results for QuickSight SPICE ingestion"
  database    = aws_glue_catalog_database.comparison_engine.name
  workgroup   = aws_athena_workgroup.comparison_analytics.id
  query       = local.comparison_dashboard_sql
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.comparison_results.id

  rule {
    id     = "expire-athena-query-results"
    status = "Enabled"

    filter {
      prefix = "athena-results/"
    }

    expiration {
      days = 7
    }
  }
}

resource "aws_iam_role" "quicksight_athena" {
  count = var.enable_quicksight ? 1 : 0
  name  = "comparison-engine-quicksight-athena-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = "quicksight.amazonaws.com"
      }
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "quicksight_athena" {
  count = var.enable_quicksight ? 1 : 0
  name  = "comparison-engine-quicksight-athena-policy"
  role  = aws_iam_role.quicksight_athena[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StartQueryExecution",
          "athena:StopQueryExecution"
        ]
        Resource = aws_athena_workgroup.comparison_analytics.arn
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions"
        ]
        Resource = [
          aws_glue_catalog_database.comparison_engine.arn,
          aws_glue_catalog_table.comparison_results.arn,
          "arn:aws:glue:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:catalog"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.comparison_results.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "${aws_s3_bucket.comparison_results.arn}/comparison-results/*",
          "${aws_s3_bucket.comparison_results.arn}/athena-results/*"
        ]
      }
    ]
  })
}

resource "aws_quicksight_data_source" "comparison_athena" {
  count          = var.enable_quicksight ? 1 : 0
  data_source_id = "comparison-engine-athena"
  name           = "Comparison Engine Athena"
  type           = "ATHENA"

  parameters {
    athena {
      role_arn   = aws_iam_role.quicksight_athena[0].arn
      work_group = aws_athena_workgroup.comparison_analytics.name
    }
  }

  permission {
    principal = var.quicksight_principal_arn
    actions = [
      "quicksight:DeleteDataSource",
      "quicksight:DescribeDataSource",
      "quicksight:DescribeDataSourcePermissions",
      "quicksight:PassDataSource",
      "quicksight:UpdateDataSource",
      "quicksight:UpdateDataSourcePermissions"
    ]
  }
}

resource "aws_quicksight_data_set" "comparison_results" {
  count       = var.enable_quicksight ? 1 : 0
  data_set_id = "comparison-engine-results"
  name        = "Comparison Engine Results"
  import_mode = "SPICE"

  physical_table_map {
    physical_table_map_id = "comparison-results"

    custom_sql {
      data_source_arn = aws_quicksight_data_source.comparison_athena[0].arn
      name            = "Flattened comparison results"
      sql_query       = local.comparison_dashboard_sql

      dynamic "columns" {
        for_each = local.quicksight_columns

        content {
          name = columns.value.name
          type = columns.value.type
        }
      }
    }
  }

  permissions {
    principal = var.quicksight_principal_arn
    actions = [
      "quicksight:CancelIngestion",
      "quicksight:CreateIngestion",
      "quicksight:DeleteDataSet",
      "quicksight:DescribeDataSet",
      "quicksight:DescribeDataSetPermissions",
      "quicksight:DescribeIngestion",
      "quicksight:ListIngestions",
      "quicksight:PassDataSet",
      "quicksight:UpdateDataSet",
      "quicksight:UpdateDataSetPermissions"
    ]
  }

  row_level_permission_data_set {
    arn               = aws_quicksight_data_set.comparison_result_access[0].arn
    format_version    = "VERSION_1"
    namespace         = "default"
    permission_policy = "GRANT_ACCESS"
    status            = "ENABLED"
  }
}

resource "aws_quicksight_data_set" "comparison_result_access" {
  count       = var.enable_quicksight ? 1 : 0
  data_set_id = "comparison-engine-result-access"
  name        = "Comparison Engine Result Access"
  import_mode = "SPICE"

  physical_table_map {
    physical_table_map_id = "comparison-result-access"

    custom_sql {
      data_source_arn = aws_quicksight_data_source.comparison_athena[0].arn
      name            = "Registered reader result access"
      sql_query       = local.quicksight_rls_sql

      columns {
        name = "UserName"
        type = "STRING"
      }

      columns {
        name = "user_id"
        type = "STRING"
      }
    }
  }

  permissions {
    principal = var.quicksight_principal_arn
    actions = [
      "quicksight:CancelIngestion",
      "quicksight:CreateIngestion",
      "quicksight:DeleteDataSet",
      "quicksight:DescribeDataSet",
      "quicksight:DescribeDataSetPermissions",
      "quicksight:DescribeIngestion",
      "quicksight:ListIngestions",
      "quicksight:PassDataSet",
      "quicksight:UpdateDataSet",
      "quicksight:UpdateDataSetPermissions"
    ]
  }
}

resource "aws_quicksight_refresh_schedule" "comparison_results" {
  count       = var.enable_quicksight ? 1 : 0
  data_set_id = aws_quicksight_data_set.comparison_results[0].data_set_id
  schedule_id = "daily-comparison-results"

  schedule {
    refresh_type = "FULL_REFRESH"

    schedule_frequency {
      interval        = "DAILY"
      time_of_the_day = "02:00"
      timezone        = "Asia/Kolkata"
    }
  }
}
