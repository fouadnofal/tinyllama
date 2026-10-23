# Learner / sandbox AWS account with restricted IAM.
# terraform apply -var-file=envs/sandbox.tfvars
#
# Check what your sandbox allows first:
#   aws sts get-caller-identity
#   aws iam list-instance-profiles --query "InstanceProfiles[].InstanceProfileName"
region        = "us-east-1"      # many sandboxes allow only us-east-1 / us-west-2
instance_type = "m7i-flex.large" # if denied, try "t3.large" or "c7i-flex.large"

# Most sandboxes block creating IAM roles -> reuse the provided profile.
create_iam_role           = false
existing_instance_profile = "LabInstanceProfile" # AWS Academy name; change to whatever list-instance-profiles shows

use_elastic_ip = true
allowed_cidr   = "0.0.0.0/0"

# Usually denied in sandboxes.
budget_email       = ""
enable_github_oidc = false
