output "app_url" {
  value = "http://${local.public_ip}"
}

output "instance_id" {
  value = aws_instance.app.id
}

output "ecr_registry" {
  value = local.ecr_registry
}

output "s3_bucket" {
  value = aws_s3_bucket.exports.bucket
}

output "instance_profile" {
  value = local.instance_profile
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${var.project}"
}
