# -----------------------------------------------------------------------------
# dev environment
#   main.tf      network + container registry (Phase 1)
#   security.tf  security groups that connect the pieces
#   app.tf       ECS cluster, load balancer, database, app service (Phase 1b)
# -----------------------------------------------------------------------------

locals {
  name = "${var.project}-${var.environment}"
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  name       = local.name
  cidr_block = var.vpc_cidr
  az_count   = 2

  # See var.enable_nat_gateway: decides whether app tasks run in private
  # subnets (behind NAT) or in public subnets (no NAT, cheaper).
  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = true
}

# -----------------------------------------------------------------------------
# Container registry
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  name = "${local.name}-app"

  # Tags can't be overwritten, so "v1.2.3" always means the same image.
  image_tag_mutability = "IMMUTABLE"

  # Lets `terraform destroy` remove the repo even if it still has images.
  # Fine for a lab; set to false for real environments.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Keep storage costs down: drop untagged images after 7 days and keep only
# the 20 most recent tagged images.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 20 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}
