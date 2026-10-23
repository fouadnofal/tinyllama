#!/usr/bin/env bash
# Runs ON the EC2 instance (invoked by SSM from GitHub Actions, or manually).
# Pulls the latest images from ECR and restarts the stack.
set -euo pipefail
cd /opt/app
set -a; source .env; set +a

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d --remove-orphans
docker image prune -f
