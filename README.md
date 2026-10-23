# TinyLlama on AWS — Containerized AI App

A web chat UI → FastAPI backend → TinyLlama (served by Ollama), packaged as two Docker
images, stored in ECR, running on EC2, with IAM, S3, CloudWatch, Terraform and GitHub Actions.

```
Browser ──HTTP:80──▶ EC2 (m7i-flex.large, Amazon Linux 2023)
                      ├─ api container (FastAPI + static UI) ──▶ S3 (conversation exports)
                      └─ inference container (Ollama + TinyLlama, internal only)
                         │ logs (awslogs driver) + CW agent metrics
                         ▼
                      CloudWatch (log group, metric filters, dashboard, CPU alarm)
GitHub Actions ──OIDC──▶ build → push to ECR → SSM "deploy.sh" on EC2
```

## Repo layout

| Path | Purpose | Phase |
|---|---|---|
| `api/` | FastAPI backend + web UI (`app/static/index.html`) | 1 |
| `inference/Dockerfile` | Ollama image with TinyLlama weights baked in | 2 |
| `docker-compose.yml` | Local run of both containers | 2 |
| `infra/*.tf` | ECR, EC2, IAM, S3, CloudWatch, security group, GitHub OIDC role | 3–5 |
| `infra/user_data.sh` | EC2 bootstrap: Docker, Compose, CloudWatch agent, app files | 3–4 |
| `deploy/` | Production compose file + `deploy.sh` (pull from ECR, restart) | 3 |
| `.github/workflows/deploy.yml` | CI/CD | 5 |

---

## Phase 1–2: Run locally

Prereqs: Docker Desktop (give it ≥ 4 GB RAM).

```bash
docker compose up --build
# open http://localhost:8000
```

The first build downloads TinyLlama (~640 MB) into the inference image. API endpoints:

- `GET /health` — API + model status
- `POST /api/chat` — `{"messages":[{"role":"user","content":"Hi"}]}`
- `POST /api/export` — saves the conversation JSON to S3 (only when `S3_BUCKET` is set)

Quick test without the UI:

```bash
curl -s localhost:8000/api/chat -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Explain Docker in one sentence"}]}'
```

## Phase 3–4: Deploy to AWS with Terraform

All AWS resources are created by Terraform in `infra/`. The same code supports two
account types; you pick one with a variables file:

| | `envs/free-tier.tfvars` | `envs/sandbox.tfvars` |
|---|---|---|
| Account | Your own account on the Free Tier | Learner / sandbox account |
| EC2 | `m7i-flex.large` (Free Tier eligible, 8 GB) | `m7i-flex.large` (change if the sandbox denies it) |
| IAM role | Terraform creates a least-privilege role | Reuses the sandbox's profile (e.g. `LabInstanceProfile`) |
| Budget alert | Optional (`budget_email`) | Off |
| GitHub OIDC (CI/CD) | Optional (`enable_github_oidc`) | Off |

**0. Install the tools (Windows)**

```powershell
winget install Hashicorp.Terraform
winget install Amazon.AWSCLI
# reopen the terminal, then:
terraform version
aws --version
```

**1. Connect the AWS CLI to your account**

*Free Tier account:* in the console, go to IAM → Users → create a user for yourself → Security credentials → create an access key. Then run:

```powershell
aws configure --profile freetier     # region: us-east-1
$env:AWS_PROFILE = "freetier"
```

*Sandbox:* copy the temporary credentials the sandbox shows you (often under "AWS Details" / "AWS CLI")
into `%USERPROFILE%\.aws\credentials` as a `[sandbox]` profile, then run `$env:AWS_PROFILE = "sandbox"`.
Sandbox credentials usually expire after a few hours, so re-copy them when Terraform says the token has expired.

Check that it works, and (sandbox only) find the instance profile name:

```powershell
aws sts get-caller-identity
aws iam list-instance-profiles --query "InstanceProfiles[].InstanceProfileName"
```

**2. Create the infrastructure**

```powershell
cd infra
terraform init
terraform plan  -var-file=envs/free-tier.tfvars      # or envs/sandbox.tfvars
terraform apply -var-file=envs/free-tier.tfvars
```

Before applying, edit the tfvars file: set `allowed_cidr` to your IP (`curl.exe ifconfig.me`, then add `/32`)
and, on the Free Tier, set `budget_email`.

Note the outputs: `app_url`, `instance_id`, `ecr_registry`, `dashboard_url`. Show them again any time with `terraform output`.

> If the sandbox denies something (e.g. `UnauthorizedOperation` for an instance type or service), change that
> value in `envs/sandbox.tfvars` and run `apply` again. Terraform only creates what's still missing.

**2. Push the images to ECR** (first time — afterwards CI does this)

PowerShell (Docker Desktop must be running):

```powershell
$REG = terraform output -raw ecr_registry
aws ecr get-login-password | docker login --username AWS --password-stdin $REG

docker build -t "$REG/tinyllama-api:latest" ../api
docker push "$REG/tinyllama-api:latest"
docker build -t "$REG/tinyllama-inference:latest" ../inference
docker push "$REG/tinyllama-inference:latest"
```

**3. Start the app on EC2**

Wait about 3 minutes after `apply` so the instance finishes its first-boot setup, then run:

```powershell
aws ssm send-command --instance-ids (terraform output -raw instance_id) `
  --document-name AWS-RunShellScript --parameters 'commands=["/opt/app/deploy.sh"]'
```

The first start pulls about 1.5 GB from ECR, so give it 1–2 minutes before opening `app_url`.

Open `app_url`. For a shell on the instance (no SSH key needed):
`aws ssm start-session --target <instance_id>`.

**4. Monitoring** — open `dashboard_url`. You get EC2 CPU, memory % (CloudWatch agent),
chat latency avg/p90 and inference errors (both extracted from the API's structured JSON logs),
plus a CPU > 85% alarm. Raw logs are in the `/tinyllama/app` log group (`api` and `inference` streams).

## Phase 5: CI/CD

Free Tier account only. Sandbox credentials expire after a few hours and IAM roles can't be created there,
so on a sandbox, deploy manually with steps 2–3 above.

1. Push the repo to GitHub.
2. In `envs/free-tier.tfvars`, set `enable_github_oidc = true` and `github_repo = "you/tinyllama-aws"`, then run `terraform apply -var-file=envs/free-tier.tfvars` again.
3. In GitHub → Settings → Secrets → Actions, add:

| Secret | Value |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | `terraform output -raw github_deploy_role_arn` |
| `EC2_INSTANCE_ID` | `terraform output -raw instance_id` |

Every push to `main` builds the API image, rebuilds the inference image only if `inference/` changed,
pushes to ECR (tagged with the commit SHA and `latest`), and redeploys via SSM.
If you change `region` in Terraform, also change `AWS_REGION` in the workflow.

## Cost control

**Free Tier:** new accounts (created on or after 15 Jul 2025) get $100 in credits, plus up to $100 more
for starter activities. Launching EC2 and creating a Budget both count, and this project does both.
On the *Free plan* you are never charged: the account just pauses when the credits run out or 6 months pass.
Usage is billed against the credits at normal rates (us-east-1, approximate):

| Resource | Approx. rate | Credits used if left on 24/7 |
|---|---|---|
| m7i-flex.large | ~$0.096/hr | ~$70/month |
| 30 GB gp3 EBS | ~$0.08/GB-month | ~$2.4/month |
| Elastic IP (public IPv4) | ~$0.005/hr | ~$3.6/month |
| ECR (~1.5 GB images), S3, CloudWatch | small | ~$1/month |

Stopping the instance between sessions makes the credits last for months:

```powershell
aws ec2 stop-instances  --instance-ids (terraform output -raw instance_id)
aws ec2 start-instances --instance-ids (terraform output -raw instance_id)   # containers restart automatically
```

At the end of the project, tear everything down with
`terraform destroy -var-file=envs/free-tier.tfvars` (or `sandbox.tfvars`).
Sandbox accounts usually have their own budget, and many stop instances automatically when the session ends.

## Ideas for extending (proposal "evolution" section)

- **Streaming responses** — Ollama supports `stream: true`; return a FastAPI `StreamingResponse` for token-by-token UI.
- **ECS on EC2 / Fargate** — replace the single instance with an ECS service behind an Application Load Balancer; the same ECR images work unchanged.
- **HTTPS** — ALB + ACM certificate + Route 53 domain.
- **Load testing** — use `locust` or `hey` against `/api/chat` and compare latency/CPU across c7i-flex.large / m7i-flex.large (both Free Tier eligible) for the "performance and cost" evaluation.
- **Auth / rate limiting** — Amazon Cognito, or a simple API key + per-IP limit in FastAPI.
