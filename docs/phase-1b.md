# Phase 1b: Run the app on AWS (ALB + ECS Fargate + RDS)

Phase 1 built the network and the image registry. Phase 1b runs a real app on
it and adds a second pipeline that ships new versions automatically.

## What gets built

```
                 Internet
                    │  HTTP :80
          ┌─────────▼─────────┐
          │ Application Load  │  public subnets, 2 AZs
          │ Balancer (ALB)    │  health-checks /health
          └─────────┬─────────┘
                    │  :8000 (only from the ALB's security group)
          ┌─────────▼─────────┐
          │ ECS Fargate tasks │  1–2 tasks, CPU auto scaling
          │ (FastAPI app)     │  logs → CloudWatch Logs
          └─────────┬─────────┘
                    │  :5432 (only from the app's security group)
          ┌─────────▼─────────┐
          │ RDS Postgres 17   │  private subnets, never public
          └───────────────────┘
                    ▲
   password lives in Secrets Manager (created by RDS); ECS injects it
   into the container at start-up. It never appears in code or Terraform.
```

New and changed files:

```
app/                          the sample API (FastAPI + Postgres)
  app/main.py
  tests/test_main.py
  Dockerfile                  multi-stage, non-root, health check
  docker-compose.yml          run app + Postgres on your laptop
infra/modules/alb/            load balancer, target group, listener
infra/modules/rds/            Postgres, subnet group, security group
infra/modules/ecs-service/    task definition, service, IAM roles, logs, auto scaling
infra/envs/dev/main.tf        VPC + ECR (unchanged resources, just reorganised)
infra/envs/dev/security.tf    app security group (now: only from the ALB)
infra/envs/dev/app.tf         wires cluster + ALB + DB + service together
bootstrap/main.tf             + least-privilege deploy role for the app pipeline
.github/workflows/app.yml     test → build → scan → push → deploy
```

### Two pipelines, two owners

| | `terraform.yml` | `app.yml` |
|---|---|---|
| Triggers on | `infra/**` | `app/**` |
| Owns | All infrastructure, including the *first* task definition | The image version running in ECS |
| AWS role | `devops-lab-github-apply` (admin) | `devops-lab-github-deploy` (push + deploy only) |

The ECS service tells Terraform to ignore its `task_definition`, so a
`terraform apply` never rolls the app back to an old image. The app pipeline
always starts from the latest task definition revision, so settings you change
in Terraform (env vars, CPU, memory) are picked up on the next release.

## Cost

Approximate, based on Singapore on-demand prices. Check the
[AWS Pricing Calculator](https://calculator.aws/) for exact figures.

| Resource | Roughly |
|---|---|
| ALB (plus 2 public IPv4 addresses) | USD 0.70/day |
| Fargate: 1 task, 0.25 vCPU / 0.5 GB (plus its public IP) | USD 0.50/day |
| RDS db.t4g.micro + 20 GB gp3 | USD 0.70/day |
| Secrets Manager secret, CloudWatch Logs | a few cents |
| **Total with defaults** | **about USD 2/day (~USD 60/month if left running)** |
| NAT Gateway, if `enable_nat_gateway = true` | + about USD 1.50/day plus data |

**Destroy at the end of every session** (see [Tearing down](#tearing-down)).
Your free-tier credits or allowances may cover part of this.

---

## Step 1: Update bootstrap (adds the deploy role)

```powershell
cd bootstrap
terraform plan     # expect: 2 to add (role + policy), 0 to change, 0 to destroy
terraform apply
terraform output github_deploy_role_arn
```

In GitHub, go to **Settings → Secrets and variables → Actions → Variables**
and add **`AWS_DEPLOY_ROLE_ARN`** with that value. Add it at **repository**
level and on the **`dev` environment**, the same way as your other variables.

## Step 2: Try the app locally (optional, about 2 minutes)

```powershell
cd app
docker compose up --build
```

Open <http://localhost:8000/db>. You should see the Postgres version. Press
`Ctrl+C` to stop, then run `docker compose down`.

## Step 3: Push a first image (recommended)

Terraform's first task definition points at the tag `initial`. Pushing it by
hand also teaches you how ECR login works:

```powershell
cd infra\envs\dev
$ECR = terraform output -raw ecr_repository_url
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin $ECR.Split('/')[0]

cd ..\..\..
docker build --platform linux/amd64 -t "${ECR}:initial" app
docker push "${ECR}:initial"
```

> If you ran `terraform destroy` after Phase 1, the ECR repo doesn't exist
> right now. Skip this step; the pipeline will handle it.
>
> If you skip this step, the first tasks fail to start (the image doesn't
> exist) until the app pipeline deploys a real version a few minutes later.
> That's harmless, just noisy.

## Step 4: Open a pull request

```powershell
git add -A
git commit -m "Phase 1b: ALB, ECS Fargate, RDS and app pipeline"
git push -u origin phase-1b
```

Open a PR to `main`. Both pipelines run:

- **terraform / plan**: read the plan comment. Expect around **25 resources
  to add**. Two existing things go away, on purpose: the app security group is
  shown as `must be replaced` (its description changed), and the old
  `app_from_vpc` rule is destroyed (replaced by `app_from_alb`). The VPC,
  subnets and ECR repo must **not** be destroyed or replaced. If the plan says
  they will be, stop and check before merging.
- **app / lint + test, build + scan**: runs tests, builds the image, and scans it with Trivy.

## Step 5: Merge

After you merge:
1. **terraform / apply** creates everything. RDS takes **5–10 minutes**.
2. **app / deploy** waits for the ECS service to exist, pushes the image
   tagged with the commit SHA, and rolls it out. It finishes when the new
   tasks pass the ALB health checks.

If your `dev` environment has required reviewers, approve both jobs.

## Step 6: Check that it works

```powershell
cd infra\envs\dev
git pull
$URL = terraform output -raw app_url

curl.exe "$URL/"              # app name + version (the commit SHA)
curl.exe "$URL/health"        # {"status":"ok"}
curl.exe "$URL/db"            # Postgres version: the app reached RDS
curl.exe -X POST "$URL/visits"   # run a few times; the count goes up
```

Use `curl.exe`, not `curl`. In PowerShell, `curl` is an alias for a different command.

---

## Day-to-day tasks you can now practise

**Ship a change.** Edit the message in `app/app/main.py`, open a PR, and merge.
The deploy job rolls it out with no downtime. Watch the rollout in
**ECS → Clusters → devops-lab-dev → Services → Deployments**.

**Read the logs.**
```powershell
aws logs tail /ecs/devops-lab-dev-app --follow --region ap-southeast-1
```

**Shell into a running container** (needs the
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)):
```powershell
$TASK = aws ecs list-tasks --cluster devops-lab-dev --service-name devops-lab-dev-app --query "taskArns[0]" --output text
aws ecs execute-command --cluster devops-lab-dev --task $TASK --container app --interactive --command "/bin/sh"
```

**Roll back.** Point the service at the previous task definition revision:
```powershell
aws ecs list-task-definitions --family-prefix devops-lab-dev-app --sort DESC --max-items 3
aws ecs update-service --cluster devops-lab-dev --service devops-lab-dev-app --task-definition devops-lab-dev-app:<previous-revision>
```
If new tasks fail their health checks, ECS's **deployment circuit breaker**
rolls back automatically. To test it, break `/health` on purpose in a branch
and watch what happens.

**Scale.**
```powershell
aws ecs update-service --cluster devops-lab-dev --service devops-lab-dev-app --desired-count 2
```
Auto scaling also adds a task when average CPU stays above 60%.

**Find the database password** (only when you really need it):
**Secrets Manager → Secrets** → the `rds!db-...` secret → **Retrieve secret value**.

---

## Known gotchas

- **Password rotation.** RDS rotates its managed password every 7 days by
  default. ECS injects secrets only when a task *starts*, so after a rotation
  `/db` returns 503 until the tasks restart. The fix is:
  ```powershell
  aws ecs update-service --cluster devops-lab-dev --service devops-lab-dev-app --force-new-deployment
  ```
  If you destroy the environment daily, you'll never see this. Handling it
  properly is in the exercises below.
- **Tasks in public subnets.** With the default `enable_nat_gateway = false`,
  tasks get a public IP so they can pull images without a NAT Gateway. Their
  security group only allows the ALB, so nothing else can reach them. Set it
  to `true` to see the production pattern, where tasks are in private subnets.
- **Apple Silicon or ARM Windows laptops** must build with
  `--platform linux/amd64`, because the tasks run on x86.

## Tearing down

```powershell
cd infra\envs\dev
terraform destroy      # about 10 minutes; RDS is the slow part
```

This also deletes the ECR repo and its images (`force_delete = true`). To come
back the next day, run `terraform apply`, then **Actions → app → Run workflow**
on `main` to deploy the app again. You can also repeat Step 3 first.

The bootstrap stack and the deploy role cost nothing. Leave them running.

## Exercises (realistic tickets)

1. **HTTPS.** Register a domain (or use one you own) in Route 53, request an
   ACM certificate, add a `:443` listener, and redirect `:80` to it. This
   clears several Checkov findings.
2. **Lock the app to your IP.** Set `allowed_cidrs = ["<your-ip>/32"]` in a
   `terraform.tfvars` and see the ALB security group change in the plan.
3. **Least-privilege database user.** Create an `app` Postgres user with rights
   only on its own tables, store it in its own Secrets Manager secret, and stop
   using the master user from the app.
4. **Survive password rotation.** Make the app fetch the secret from Secrets
   Manager when a login fails, instead of relying on env vars set at start-up.
5. **Alarms.** Add CloudWatch alarms for ALB `HTTPCode_Target_5XX_Count` and
   `UnHealthyHostCount` (the ALB module outputs the `arn_suffix` values you need).
6. **NAT vs. VPC endpoints.** Work out the monthly cost of interface endpoints
   for ECR, Logs and Secrets Manager compared with one NAT Gateway. When would
   you choose each?
7. **Tighten the Trivy gate** to fail on `HIGH` as well as `CRITICAL`, and fix what it finds.
