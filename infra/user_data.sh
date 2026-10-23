#!/bin/bash
# Runs once on first boot of the EC2 instance.
set -euxo pipefail

dnf install -y docker amazon-cloudwatch-agent
systemctl enable --now docker
usermod -aG docker ec2-user

# Docker Compose v2 plugin
mkdir -p /usr/local/lib/docker/cli-plugins
curl -sSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# CloudWatch agent: memory + disk metrics (EC2 doesn't report these by default)
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'JSON'
{
  "metrics": {
    "append_dimensions": { "InstanceId": "$${aws:InstanceId}" },
    "metrics_collected": {
      "mem":  { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/"] }
    }
  }
}
JSON
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# App files
mkdir -p /opt/app
cat > /opt/app/.env <<EOF
AWS_REGION=${region}
ECR_REGISTRY=${ecr_registry}
LOG_GROUP=${log_group}
S3_BUCKET=${s3_bucket}
IMAGE_TAG=latest
EOF

cat > /opt/app/docker-compose.prod.yml <<'YAML'
${compose_file}
YAML

cat > /opt/app/deploy.sh <<'SH'
${deploy_sh}
SH
chmod +x /opt/app/deploy.sh

# First deploy may fail if images aren't pushed yet — CI will re-run it.
/opt/app/deploy.sh || true
