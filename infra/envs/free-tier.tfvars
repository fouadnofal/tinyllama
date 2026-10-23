# Personal AWS account on the Free Tier (created on/after 15 Jul 2025).
# terraform apply -var-file=envs/free-tier.tfvars
region          = "us-east-1"
instance_type   = "m7i-flex.large" # Free Tier eligible, 8 GB RAM
create_iam_role = true
use_elastic_ip  = true

# Your public IP, so only you can open the app while developing.
allowed_cidr = "0.0.0.0/0" # e.g. "41.x.x.x/32"

# Budget alert email (also earns a $20 Free Tier credit).
budget_email     = "" # e.g. "you@example.com"
budget_limit_usd = 10

# Phase 5 (CI/CD). Set to true after pushing the repo to GitHub.
enable_github_oidc = false
github_repo        = "" # e.g. "peter/tinyllama-aws"
