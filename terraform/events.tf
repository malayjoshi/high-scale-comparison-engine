resource "aws_cloudwatch_event_bus" "comparison_callbacks" {
  name = "comparison-engine-callbacks"
}

resource "aws_cloudwatch_event_rule" "comparison_completed" {
  name           = "comparison-engine-completed"
  event_bus_name = aws_cloudwatch_event_bus.comparison_callbacks.name

  event_pattern = jsonencode({
    source      = ["comparison-engine.worker"]
    detail-type = ["Comparison Job Completed"]
  })
}
