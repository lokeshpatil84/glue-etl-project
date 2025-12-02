locals {
  name = var.project_name
}

# S3 Buckets
resource "aws_s3_bucket" "raw" {
  bucket = "${local.name}-raw-${random_id.bucket_suffix.hex}"
}

resource "aws_s3_bucket" "processed" {
  bucket = "${local.name}-processed-${random_id.bucket_suffix.hex}"
}

resource "aws_s3_bucket" "scripts" {
  bucket = "${local.name}-scripts-${random_id.bucket_suffix.hex}"
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Bucket policies for public? No, private
resource "aws_s3_bucket_public_access_block" "raw" {
  bucket = aws_s3_bucket.raw.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "processed" {
  bucket = aws_s3_bucket.processed.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM Role for Glue
resource "aws_iam_role" "glue_role" {
  name = "${local.name}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "glue.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3" {
  name = "glue-s3-access"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.raw.arn,
          "${aws_s3_bucket.raw.arn}/*",
          aws_s3_bucket.processed.arn,
          "${aws_s3_bucket.processed.arn}/*",
          aws_s3_bucket.scripts.arn,
          "${aws_s3_bucket.scripts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Glue Script Upload
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.scripts.id
  key    = "etl_job.py"
  source = "${path.module}/glue_script.py"
  etag   = filemd5("${path.module}/glue_script.py")
}

# Glue Job
resource "aws_glue_job" "etl" {
  name     = "${local.name}-etl-job"
  role_arn = aws_iam_role.glue_role.arn

  glue_version = "4.0"
  number_of_workers = 2
  worker_type = "G.1X"
  timeout = 10

  command {
    name            = "glueetl"
    script_location = aws_s3_object.glue_script.bucket == null ? null : "s3://${aws_s3_object.glue_script.bucket}/${aws_s3_object.glue_script.key}"
    python_version  = 3
  }

  default_arguments = {
    "--TempDir" = "s3://${aws_s3_bucket.scripts.bucket}/temp/"
    "--job-bookmark-option" = "job-bookmark-disable"
    "--raw_bucket" = aws_s3_bucket.raw.bucket
    "--processed_bucket" = aws_s3_bucket.processed.bucket
  }
}

# Glue Catalog
resource "aws_glue_catalog_database" "db" {
  name = replace(local.name, "-", "_")
}

resource "aws_glue_catalog_table" "processed_table" {
  name          = "cleaned_data"
  database_name = aws_glue_catalog_database.db.name
  table_type    = "EXTERNAL_TABLE"

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.processed.bucket}/cleaned/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = false

    ser_de_info {
      name                  = "lazy_simple_serde"
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
      parameters = {
        "field.delim" = ","
        "serialization.format" = ","
      }
    }

    columns {
      name = "name"
      type = "string"
    }
    columns {
      name = "age"
      type = "int"
    }
    columns {
      name = "city"
      type = "string"
    }
  }

  parameters = {
    "classification" = "csv"
  }
}

# SQS (Future use, optional)
resource "aws_sqs_queue" "glue_trigger" {
  name                      = "${local.name}-queue"
  delay_seconds             = 0
  message_retention_seconds = 86400
}

# Lambda for S3 Trigger
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda_function.zip"

  source {
    content  = file("${path.module}/lambda_function.py")
    filename = "lambda_function.py"
  }
}

resource "aws_lambda_function" "s3_trigger" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${local.name}-s3-trigger"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      GLUE_JOB_NAME = aws_glue_job.etl.name
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name = "${local.name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_glue" {
  name = "lambda-glue-access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "glue:StartJobRun",
        "glue:GetJobRun",
        "glue:GetJob"
      ]
      Resource = aws_glue_job.etl.arn
    }]
  })
}

# S3 Notification to Lambda
resource "aws_s3_bucket_notification" "raw_bucket_notification" {
  bucket = aws_s3_bucket.raw.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_trigger.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "input/"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_trigger.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw.arn
}

# SNS & SES for Alerts
resource "aws_sns_topic" "glue_alerts" {
  name = "${local.name}-glue-alerts"
}

resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.glue_alerts.arn
  protocol  = "email"
  endpoint  = var.email_for_alerts
}

# CloudWatch Events for Glue Job Status
resource "aws_cloudwatch_event_rule" "glue_job_success" {
  name        = "${local.name}-glue-success"
  description = "Capture Glue job success"

  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Job State Change"]
    detail = {
      state   = ["SUCCEEDED"]
      jobName = [aws_glue_job.etl.name]
    }
  })
}
resource "aws_cloudwatch_event_rule" "glue_job_failed" {
  name        = "${local.name}-glue-failed"
  description = "Capture Glue job failure"

  event_pattern = jsonencode({
    source      = ["aws.glue"]
    detail-type = ["Glue Job State Change"]
    detail = {
      state   = ["FAILED", "TIMEOUT", "STOPPED"]
      jobName = [aws_glue_job.etl.name]
    }
  })
}


resource "aws_cloudwatch_event_target" "sns_success" {
  rule      = aws_cloudwatch_event_rule.glue_job_success.name
  target_id = "SendSuccessToSNS"
  arn       = aws_sns_topic.glue_alerts.arn

  input = jsonencode({
    default = jsonencode({
      subject = "Glue ETL Job SUCCEEDED"
      message = "Job: ${aws_glue_job.etl.name}\nStatus: SUCCESS\nTime: {{timestamp}}"
    })
  })
}

# Failure Target
resource "aws_cloudwatch_event_target" "sns_failure" {
  rule      = aws_cloudwatch_event_rule.glue_job_failed.name
  target_id = "SendFailureToSNS"
  arn       = aws_sns_topic.glue_alerts.arn

  input = jsonencode({
    default = jsonencode({
      subject = "Glue ETL Job FAILED"
      message = "Job: ${aws_glue_job.etl.name}\nStatus: FAILED\nCheck CloudWatch Logs NOW!"
    })
  })
}



