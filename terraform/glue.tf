resource "aws_glue_catalog_database" "comparison_engine" {
  name        = "comparison_engine"
  description = "Catalog for comparison-engine result datasets"
}

resource "aws_glue_catalog_table" "comparison_results" {
  name          = "comparison_results"
  database_name = aws_glue_catalog_database.comparison_engine.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"                           = "json"
    "EXTERNAL"                                 = "TRUE"
    "projection.enabled"                       = "true"
    "projection.completion_date.type"          = "date"
    "projection.completion_date.range"         = "2020-01-01,NOW"
    "projection.completion_date.format"        = "yyyy-MM-dd"
    "projection.completion_date.interval"      = "1"
    "projection.completion_date.interval.unit" = "DAYS"
    "storage.location.template"                = "s3://${aws_s3_bucket.comparison_results.id}/comparison-results/completion_date=$${completion_date}/"
  }

  partition_keys {
    name = "completion_date"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.comparison_results.id}/comparison-results/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "comparison-results-json"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
    }

    columns {
      name = "job_id"
      type = "string"
    }

    columns {
      name = "user_id"
      type = "string"
    }

    columns {
      name = "request_timestamp"
      type = "string"
    }

    columns {
      name = "comparison_completed_at"
      type = "string"
    }

    columns {
      name = "source_folder"
      type = "string"
    }

    columns {
      name = "destination_folder"
      type = "string"
    }

    columns {
      name = "files"
      type = "struct<common:array<string>,added:array<string>,deleted:array<string>>"
    }

    columns {
      name = "file_comparisons"
      type = "array<struct<filename:string,primary_key_column:string,columns:struct<matching:array<string>,added:array<string>,deleted:array<string>>,rows:struct<matching_primary_key_count:bigint,added_primary_keys:array<string>,deleted_primary_keys:array<string>,cell_mismatches:array<struct<primary_key:string,column:string,source_value:string,destination_value:string>>>>>"
    }
  }
}
