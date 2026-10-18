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

  # Off by default to keep costs near zero while you learn.
  # Turn on when you add ECS/RDS in private subnets and they need internet.
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

# -----------------------------------------------------------------------------
# Security group for the app (used in the next step, ECS Fargate)
# -----------------------------------------------------------------------------

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "App containers. Allows inbound on the app port from inside the VPC only."
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${local.name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_vpc" {
  security_group_id = aws_security_group.app.id
  description       = "App port from within the VPC (e.g. a load balancer)"
  cidr_ipv4         = module.vpc.vpc_cidr_block
  from_port         = var.app_port
  to_port           = var.app_port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_all_out" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound to anywhere (pull images, call APIs)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
