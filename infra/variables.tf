variable "project" {
  type    = string
  default = "tinyllama"
}

# us-east-1 works on Free Tier accounts and on most learner sandboxes
# (many sandboxes only allow us-east-1 / us-west-2).
variable "region" {
  type    = string
  default = "us-east-1"
}

# TinyLlama needs ~1.5 GB RAM plus Docker overhead.
# Free Tier eligible (accounts created on/after 15 Jul 2025):
#   m7i-flex.large (2 vCPU / 8 GB)  <- recommended
#   c7i-flex.large (2 vCPU / 4 GB)  <- works, less headroom
#   t3.small (2 GB) / t3.micro (1 GB) are too small for the model.
variable "instance_type" {
  type    = string
  default = "m7i-flex.large"
}

variable "root_volume_gb" {
  type    = number
  default = 30
}

# Restrict to your own IP while developing, e.g. "41.x.x.x/32".
variable "allowed_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

# ---- IAM: sandbox accounts often block iam:CreateRole ----
# true  -> Terraform creates a least-privilege role + instance profile (Free Tier / normal account)
# false -> reuse an instance profile that already exists (e.g. "LabInstanceProfile" in AWS Academy)
variable "create_iam_role" {
  type    = bool
  default = true
}

variable "existing_instance_profile" {
  type    = string
  default = ""
}

# Static public IP. Costs ~$0.005/hr (covered by Free Tier credits).
# false -> public IP changes every time the instance is stopped/started.
variable "use_elastic_ip" {
  type    = bool
  default = true
}

# ---- Optional extras ----
# Monthly cost budget with email alerts. Creating a budget is also one of the
# Free Tier "earn $20 credit" activities. Leave empty to skip (some sandboxes deny Budgets).
variable "budget_email" {
  type    = string
  default = ""
}

variable "budget_limit_usd" {
  type    = number
  default = 10
}

# GitHub Actions OIDC deploy role (Phase 5). Needs IAM permissions, so keep false on sandboxes.
variable "enable_github_oidc" {
  type    = bool
  default = false
}

variable "github_repo" {
  description = "owner/repo allowed to deploy, e.g. peter/tinyllama-aws"
  type        = string
  default     = ""
}
