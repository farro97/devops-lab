# devops-lab: Phase 1 (Terraform on AWS)

A learning project that builds real-world AWS infrastructure with Terraform and
deploys it through a GitHub Actions pipeline, the way a DevOps team would.

## What's in here

```
devops-lab/
├── bootstrap/                 # Run ONCE by hand. Creates state bucket + CI roles.
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── infra/
│   ├── modules/
│   │   └── vpc/               # Reusable network module
│   └── envs/
│       └── dev/               # The dev environment: VPC + ECR + app security group
│           ├── versions.tf    # Provider + S3 backend
│           ├── main.tf
│           ├── variables.tf
│           ├── outputs.tf
│           └── backend.hcl.example
└── .github/workflows/
    └── terraform.yml          # PR: fmt/validate/scan/plan  ·  main: apply
```

### How the pieces fit

```
 You (laptop)                     GitHub                          AWS
 ────────────                     ──────                          ───
 terraform apply  ──────────────────────────────────────────▶  bootstrap/
   (once, local state)                                          • S3 state bucket
                                                                • GitHub OIDC provider
                                                                • plan role / apply role

 git push (branch) ──▶ Pull request ──▶ plan job ──(OIDC)──▶  plan role (read-only)
                                        posts plan as a comment

 merge to main     ──▶ apply job (environment: dev) ─(OIDC)─▶  apply role
                                                                • VPC, subnets, IGW
                                                                • ECR repository
                                                                • app security group
```

## Prerequisites

- An AWS account with MFA on root, and an admin user or SSO profile for daily use
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), logged in (`aws sts get-caller-identity` should work)
- [Terraform 1.10 or newer](https://developer.hashicorp.com/terraform/install) (needed for S3-native state locking)
- A GitHub account and an empty repo, e.g. `devops-lab`
- **An AWS Budget alert** (Billing → Budgets) at around USD 10–20

## Step 1: Bootstrap (once, from your laptop)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # set github_owner and github_repo
terraform init
terraform plan        # read it! know what you're creating
terraform apply
terraform output      # copy these three values
```

> **Note:** If your AWS account already has a GitHub OIDC provider, the apply will
> fail with `EntityAlreadyExists`. Import it instead:
> `terraform import aws_iam_openid_connect_provider.github arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com`

The bootstrap stack keeps its state locally (`bootstrap/terraform.tfstate`).
That's normal for this "chicken-and-egg" stack. Don't commit the state file, and
don't delete it.

## Step 2: Run the dev environment locally first

```bash
cd infra/envs/dev
cp backend.hcl.example backend.hcl   # paste the state_bucket output
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Check the result in the AWS console (VPC → Your VPCs, and ECR → Repositories).

## Step 3: Hand it over to GitHub Actions

1. Push this folder to your GitHub repo.
2. In the repo, go to **Settings → Secrets and variables → Actions → Variables**
   and add:

   | Variable | Value |
   |---|---|
   | `AWS_REGION` | `ap-southeast-1` |
   | `TF_STATE_BUCKET` | bootstrap output `state_bucket` |
   | `AWS_PLAN_ROLE_ARN` | bootstrap output `github_plan_role_arn` |
   | `AWS_APPLY_ROLE_ARN` | bootstrap output `github_apply_role_arn` |

   These aren't secrets (an ARN on its own grants nothing), so plain variables are fine.
3. Go to **Settings → Environments → New environment**, name it `dev`.
   Optionally add yourself as a **required reviewer**, so every apply waits for your approval.
4. Protect `main`: **Settings → Branches** → require a pull request before merging.

### Try the workflow

```bash
git checkout -b test-change
# e.g. change app_port default to 8080 in infra/envs/dev/variables.tf
git commit -am "Change app port" && git push -u origin test-change
```

Open a pull request. The bot posts the plan as a comment. Review it, merge, and
watch the apply job run.

## Costs

With the defaults, this phase costs close to **nothing**:

| Resource | Cost |
|---|---|
| VPC, subnets, route tables, IGW, security groups, S3 gateway endpoint | Free |
| ECR | Storage only, a few cents per GB per month |
| S3 state bucket | A few cents |
| **NAT Gateway** (`enable_nat_gateway = true`) | **Roughly USD 1+/day, plus data.** Off by default |

Tear down the dev environment when you're done for the day:

```bash
cd infra/envs/dev && terraform destroy
```

Leave the bootstrap stack running. It costs almost nothing.

## Things to learn from this code

Read the comments in each file. Key ideas:

- **Remote state + locking**: why a team can't keep state on one laptop.
- **Modules**: `modules/vpc` is reusable; `envs/dev` just calls it with values.
  Adding `envs/prod` is mostly copy-and-change-variables.
- **`count` and `cidrsubnet()`**: generating subnets from a list of AZs.
- **OIDC + least privilege**: PRs get a read-only role; only `main` via the `dev`
  environment can change things.
- **Plan on PR, apply on merge**: the standard GitOps-style Terraform workflow.

## Exercises (do these yourself)

The Checkov scan in the pipeline reports these on purpose. Each is a realistic
ticket you might get at work:

1. **VPC flow logs** (`CKV2_AWS_11`): send flow logs to CloudWatch Logs with a
   7-day retention. You'll need an IAM role for the flow-logs service.
2. **KMS encryption for ECR** (`CKV_AWS_136`): create a KMS key and use
   `encryption_type = "KMS"`. Note: changing encryption replaces the repo.
3. **Unattached security group** (`CKV2_AWS_5`): this clears itself once you
   attach it to an ECS service in the next step.
4. **Scope down the apply role**: replace `AdministratorAccess` with a custom
   policy that only allows the services you use (EC2/VPC, ECR, IAM for specific
   roles, S3 for state). Use CloudTrail or IAM Access Analyzer to see what
   Terraform actually calls.
5. **Add `envs/prod`** with `single_nat_gateway = false` and `az_count = 3`, and
   a separate `prod` GitHub environment with required reviewers.
6. **Add a `tflint` step** to the `checks` job.

## Next step: Phase 1b

Add to `envs/dev`:
- An **Application Load Balancer** in the public subnets
- An **ECS Fargate** cluster, task definition and service in the private subnets,
  using the image from ECR (this is when you turn on the NAT Gateway, or add VPC
  endpoints for ECR and CloudWatch Logs instead)
- An **RDS Postgres** database with its password in **Secrets Manager**
- A second workflow that builds your Docker image, scans it with Trivy, and
  pushes it to ECR
