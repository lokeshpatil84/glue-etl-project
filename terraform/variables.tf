variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "daily-csv-processor"
}

variable "email_for_alerts" {
  description = "Email for alerts (confirm in SES)"
  type        = string
}