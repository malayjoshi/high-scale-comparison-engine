resource "aws_autoscaling_policy" "worker_scale_out" {
  name                      = "comparison-engine-worker-scale-out"
  autoscaling_group_name    = aws_autoscaling_group.comparison_engine_asg.name
  adjustment_type           = "ChangeInCapacity"
  policy_type               = "StepScaling"
  estimated_instance_warmup = 120
  enabled                   = var.autoscaling_policies_enabled

  step_adjustment {
    metric_interval_lower_bound = 0
    scaling_adjustment          = 1
  }

  lifecycle {
    ignore_changes = [predictive_scaling_configuration]
  }
}

resource "aws_autoscaling_policy" "worker_scale_in" {
  name                      = "comparison-engine-worker-scale-in"
  autoscaling_group_name    = aws_autoscaling_group.comparison_engine_asg.name
  adjustment_type           = "ChangeInCapacity"
  policy_type               = "StepScaling"
  estimated_instance_warmup = 120
  enabled                   = var.autoscaling_policies_enabled

  step_adjustment {
    metric_interval_upper_bound = 0
    scaling_adjustment          = -1
  }

  lifecycle {
    ignore_changes = [predictive_scaling_configuration]
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_scale_out" {
  alarm_name          = "comparison-engine-worker-backlog-high"
  alarm_description   = "Scale out when queued and in-flight folder pairs exceed two per worker"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_autoscaling_policy.worker_scale_out.arn]

  metric_query {
    id          = "backlog"
    expression  = "IF(capacity > 0, (visible + inflight) / capacity, visible + inflight)"
    label       = "Folder-pair backlog per worker"
    return_data = true
  }

  metric_query {
    id = "visible"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      period      = 60
      stat        = "Average"
      dimensions = {
        QueueName = aws_sqs_queue.comparison_engine_queue.name
      }
    }
  }

  metric_query {
    id = "inflight"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesNotVisible"
      period      = 60
      stat        = "Average"
      dimensions = {
        QueueName = aws_sqs_queue.comparison_engine_queue.name
      }
    }
  }

  metric_query {
    id = "capacity"
    metric {
      namespace   = "AWS/AutoScaling"
      metric_name = "GroupInServiceInstances"
      period      = 60
      stat        = "Average"
      dimensions = {
        AutoScalingGroupName = aws_autoscaling_group.comparison_engine_asg.name
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_scale_in" {
  alarm_name          = "comparison-engine-worker-backlog-low"
  alarm_description   = "Scale in after the folder-pair backlog remains below half a task per worker"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 0.5
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_autoscaling_policy.worker_scale_in.arn]

  metric_query {
    id          = "backlog"
    expression  = "IF(capacity > 0, (visible + inflight) / capacity, visible + inflight)"
    label       = "Folder-pair backlog per worker"
    return_data = true
  }

  metric_query {
    id = "visible"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      period      = 60
      stat        = "Average"
      dimensions = {
        QueueName = aws_sqs_queue.comparison_engine_queue.name
      }
    }
  }

  metric_query {
    id = "inflight"
    metric {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesNotVisible"
      period      = 60
      stat        = "Average"
      dimensions = {
        QueueName = aws_sqs_queue.comparison_engine_queue.name
      }
    }
  }

  metric_query {
    id = "capacity"
    metric {
      namespace   = "AWS/AutoScaling"
      metric_name = "GroupInServiceInstances"
      period      = 60
      stat        = "Average"
      dimensions = {
        AutoScalingGroupName = aws_autoscaling_group.comparison_engine_asg.name
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "input_dlq" {
  alarm_name          = "comparison-engine-input-dlq-not-empty"
  alarm_description   = "Folder-pair tasks exhausted their retries"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.comparison_engine_dlq.name
  }
}

resource "aws_cloudwatch_metric_alarm" "completion_dlq" {
  alarm_name          = "comparison-engine-completion-dlq-not-empty"
  alarm_description   = "Completion callbacks exhausted their retries"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.comparison_completion_dlq.name
  }
}

resource "aws_cloudwatch_metric_alarm" "oldest_input_message" {
  alarm_name          = "comparison-engine-oldest-input-message"
  alarm_description   = "A folder-pair task has waited at least 15 minutes"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  period              = 60
  statistic           = "Maximum"
  threshold           = 900
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.comparison_engine_queue.name
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_capacity" {
  alarm_name          = "comparison-engine-worker-capacity-low"
  alarm_description   = "The ASG has fewer in-service workers than its configured minimum"
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  period              = 60
  statistic           = "Average"
  threshold           = aws_autoscaling_group.comparison_engine_asg.min_size
  treat_missing_data  = "breaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.comparison_engine_asg.name
  }
}

resource "aws_cloudwatch_metric_alarm" "database_storage" {
  alarm_name          = "comparison-engine-database-storage-low"
  alarm_description   = "RDS has less than 2 GiB of free storage"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  period              = 300
  statistic           = "Average"
  threshold           = 2147483648
  treat_missing_data  = "breaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.comparison_engine.identifier
  }
}
