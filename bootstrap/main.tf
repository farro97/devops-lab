# -----------------------------------------------------------------------------
# BOOTSTRAP STACK
# Run this ONCE, from your laptop, with local state.
# It creates the things every other stack depends on:
#   1. An S3 bucket for Terraform remote state (with native S3 locking)
#   2. A GitHub OIDC identity provider, so GitHub Actions can log in to AWS
#      without long-lived access keys
#   3. Two IAM roles for CI: a read-only "plan" role for pull requests,
#      and an "apply" role used only from the protected `dev` environment
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10" # 1.10+ is needed for S3-native state locking

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  # Bucket names are global across ALL AWS accounts, so we add the account ID.
  state_bucket = "${var.project}-tfstate-${local.account_id}"
  repo         = "${var.github_owner}/${var.github_repo}"

  # GitHub can put the token subject in one of two forms:
  #   classic:  repo:OWNER/REPO:...
  #   with IDs: repo:OWNER@OWNER_ID/REPO@REPO_ID:...
  # The ID form can't be reused if someone later takes over the same
  # username or repo name. We accept both so the roles keep working
  # whichever one GitHub sends.
  repo_subjects = compact([
    local.repo,
    var.github_owner_id != "" && var.github_repo_id != "" ? "${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}" : "",
  ])
}

# -----------------------------------------------------------------------------
# 1. Remote state bucket
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket

  # Losing your state file is painful. This stops `terraform destroy`
  # from deleting the bucket by accident.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning lets you recover an older state file if one gets corrupted.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State files can contain secrets. Never make this bucket public.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Expire old state versions after 90 days so storage doesn't grow forever.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# Reject any request that isn't over HTTPS.
data "aws_iam_policy_document" "tfstate_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# -----------------------------------------------------------------------------
# 2. GitHub OIDC provider
# GitHub Actions gets a short-lived token from GitHub, and AWS exchanges it
# for temporary credentials. No access keys are stored anywhere.
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# -----------------------------------------------------------------------------
# 3a. PLAN role (pull requests)
# Can read everything and take the state lock, but cannot change infra.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only pull requests in YOUR repo can assume this role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for r in local.repo_subjects : "repo:${r}:pull_request"]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name                 = "${var.project}-github-plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "github_plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

# `terraform plan` writes a small <key>.tflock file to take the state lock,
# so the plan role needs write access to lock files only.
data "aws_iam_policy_document" "plan_state_lock" {
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "github_plan_state_lock" {
  name   = "terraform-state-lock"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.plan_state_lock.json
}

# -----------------------------------------------------------------------------
# 3b. APPLY role (main branch, via the protected `dev` GitHub environment)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # When a job declares `environment: dev`, GitHub sets the token subject
    # to "repo:OWNER/REPO:environment:dev". Tying the role to the environment
    # means you can add required reviewers in GitHub to gate every apply.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for r in local.repo_subjects : "repo:${r}:environment:dev"]
    }
  }
}

resource "aws_iam_role" "github_apply" {
  name                 = "${var.project}-github-apply"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

# NOTE: AdministratorAccess keeps the learning path simple, because Terraform
# will create many kinds of resources in later phases. In a real company you
# would scope this down. Doing that yourself is a great exercise (see README).
resource "aws_iam_role_policy_attachment" "github_apply_admin" {
  role       = aws_iam_role.github_apply.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

# -----------------------------------------------------------------------------
# 3c. DEPLOY role (app pipeline: push image to ECR, roll out on ECS)
# Least privilege: unlike the apply role, this one cannot create or delete
# infrastructure. It can only do the handful of things a release needs.
# Uses the same trust as the apply role (main branch via the `dev` environment).
# -----------------------------------------------------------------------------

resource "aws_iam_role" "github_deploy" {
  name                 = "${var.project}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  # Logging in to ECR is account-wide; it can't be scoped to one repo.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:ecr:${var.region}:${local.account_id}:repository/${var.project}-*"]
  }

  # Task definitions can't be scoped by name for Describe/Register.
  statement {
    sid = "EcsTaskDefinitions"
    actions = [
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
    ]
    resources = ["*"]
  }

  statement {
    sid = "EcsServices"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:ecs:${var.region}:${local.account_id}:service/${var.project}-*/*"]
  }

  statement {
    sid       = "EcsTagging"
    actions   = ["ecs:TagResource"]
    resources = ["arn:${data.aws_partition.current.partition}:ecs:${var.region}:${local.account_id}:task-definition/${var.project}-*:*"]
  }

  # A new task definition revision references the task + execution roles,
  # so the pipeline must be allowed to "pass" them to ECS. Only roles that
  # follow the "<project>-*-ecs-*" naming convention, and only to ECS tasks.
  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/${var.project}-*-ecs-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy-app"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
