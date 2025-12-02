output "raw_bucket_name" {
  value = aws_s3_bucket.raw.bucket
}

output "processed_bucket_name" {
  value = aws_s3_bucket.processed.bucket
}

output "glue_job_name" {
  value = aws_glue_job.etl.name
}

output "sns_topic_arn" {
  value = aws_sns_topic.glue_alerts.arn
}