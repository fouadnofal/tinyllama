terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = { Project = var.project } }
}

data "aws_caller_identity" "me" {}

locals {
  ecr_registry = "${data.aws_caller_identity.me.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  log_group    = "/${var.project}/app"
}

# ---------------- ECR ----------------
resource "aws_ecr_repository" "repo" {
  for_each             = toset(["tinyllama-api", "tinyllama-inference"])
  name                 = each.key
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "keep_recent" {
  for_each   = aws_ecr_repository.repo
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 }
      action       = { type = "expire" }
    }]
  })
}

# ---------------- S3 ----------------
resource "aws_s3_bucket" "exports" {
  bucket_prefix = "${var.project}-exports-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "exports" {
  bucket                  = aws_s3_bucket.exports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "exports" {
  bucket = aws_s3_bucket.exports.id
  rule {
    id     = "expire-old-exports"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
  }
}

# ---------------- CloudWatch ----------------
resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group
  retention_in_days = 7
}

# Turns the API's structured "latency_ms" log field into a metric.
resource "aws_cloudwatch_log_metric_filter" "latency" {
  name           = "chat-latency"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.event = \"chat\" }"
  metric_transformation {
    name      = "ChatLatencyMs"
    namespace = var.project
    value     = "$.latency_ms"
    unit      = "Milliseconds"
  }
}

resource "aws_cloudwatch_log_metric_filter" "errors" {
  name           = "inference-errors"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.event = \"inference_error\" }"
  metric_transformation {
    name      = "InferenceErrors"
    namespace = var.project
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${var.project}-high-cpu"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { InstanceId = aws_instance.app.id }
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.project
  dashboard_body = jsonencode({
    widgets = [
      { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = {
        title = "EC2 CPU", region = var.region, stat = "Average", period = 300,
      metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id]] } },
      { type = "metric", x = 12, y = 0, width = 12, height = 6, properties = {
        title = "Chat latency (ms)", region = var.region, period = 300,
      metrics = [[var.project, "ChatLatencyMs", { stat = "Average" }], ["...", { stat = "p90" }]] } },
      { type = "metric", x = 0, y = 6, width = 12, height = 6, properties = {
        title = "Memory used %", region = var.region, stat = "Average", period = 300,
      metrics = [["CWAgent", "mem_used_percent", "InstanceId", aws_instance.app.id]] } },
      { type = "metric", x = 12, y = 6, width = 12, height = 6, properties = {
        title = "Inference errors", region = var.region, stat = "Sum", period = 300,
      metrics = [[var.project, "InferenceErrors"]] } },
    ]
  })
}

# ---------------- IAM (EC2 instance role) ----------------
# Skipped when create_iam_role = false (sandbox): the existing profile is used instead.
resource "aws_iam_role" "ec2" {
  count = var.create_iam_role ? 1 : 0
  name  = "${var.project}-ec2-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = var.create_iam_role ? toset([
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
  ]) : toset([])
  role       = aws_iam_role.ec2[0].name
  policy_arn = each.value
}

# Least privilege: write logs to our group, put objects in our bucket only.
resource "aws_iam_role_policy" "app" {
  count = var.create_iam_role ? 1 : 0
  name  = "${var.project}-app"
  role  = aws_iam_role.ec2[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"],
      Resource = "${aws_cloudwatch_log_group.app.arn}:*" },
      { Effect = "Allow", Action = ["s3:PutObject"],
      Resource = "${aws_s3_bucket.exports.arn}/*" },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  count = var.create_iam_role ? 1 : 0
  name  = "${var.project}-ec2-profile"
  role  = aws_iam_role.ec2[0].name
}

locals {
  instance_profile = var.create_iam_role ? aws_iam_instance_profile.ec2[0].name : var.existing_instance_profile
}

# ---------------- Budget (optional) ----------------
resource "aws_budgets_budget" "monthly" {
  count        = var.budget_email == "" ? 0 : 1
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}

# ---------------- Networking ----------------
data "aws_vpc" "default" { default = true }

resource "aws_security_group" "app" {
  name   = "${var.project}-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  # No SSH port: shell access is through SSM Session Manager.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------- EC2 ----------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  iam_instance_profile   = local.instance_profile
  vpc_security_group_ids = [aws_security_group.app.id]

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  lifecycle {
    precondition {
      condition     = var.create_iam_role || var.existing_instance_profile != ""
      error_message = "Set existing_instance_profile (e.g. \"LabInstanceProfile\") when create_iam_role = false."
    }
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    region       = var.region
    ecr_registry = local.ecr_registry
    log_group    = local.log_group
    s3_bucket    = aws_s3_bucket.exports.bucket
    compose_file = file("${path.module}/../deploy/docker-compose.prod.yml")
    deploy_sh    = file("${path.module}/../deploy/deploy.sh")
  })
  user_data_replace_on_change = true

  tags = { Name = "${var.project}-app" }
}

resource "aws_eip" "app" {
  count    = var.use_elastic_ip ? 1 : 0
  instance = aws_instance.app.id
}

locals {
  public_ip = var.use_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
}
