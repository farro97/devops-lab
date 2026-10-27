# -----------------------------------------------------------------------------
# Phase 1b: run the app
#
#   Internet -> ALB (public subnets) -> ECS Fargate tasks -> RDS Postgres
#                                                           (private subnets)
# -----------------------------------------------------------------------------

locals {
  # With a NAT Gateway, tasks run in private subnets (the production pattern).
  # Without one, tasks run in public subnets with a public IP so they can
  # still pull images. Their security group only accepts the ALB, so they
  # still aren't reachable directly from the internet.
  app_subnet_ids = var.enable_nat_gateway ? module.vpc.private_subnet_ids : module.vpc.public_subnet_ids
}

# --- ECS cluster -------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name = "containerInsights"
    # Container Insights gives per-task CPU/memory dashboards but is billed
    # as custom metrics. Turn on when you get to Phase 5 (observability).
    value = var.container_insights ? "enhanced" : "disabled"
  }
}

# --- Load balancer -----------------------------------------------------------

module "alb" {
  source = "../../modules/alb"

  name                     = local.name
  vpc_id                   = module.vpc.vpc_id
  public_subnet_ids        = module.vpc.public_subnet_ids
  target_port              = var.app_port
  target_security_group_id = aws_security_group.app.id
  health_check_path        = "/health"
  allowed_cidrs            = var.allowed_cidrs
}

# --- Database ----------------------------------------------------------------

module "db" {
  source = "../../modules/rds"

  name                       = local.name
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnet_ids
  allowed_security_group_ids = [aws_security_group.app.id]

  instance_class = var.db_instance_class
  db_name        = "app"

  # Lab settings: cheap and easy to tear down. Flip these for prod.
  multi_az            = false
  deletion_protection = false
  skip_final_snapshot = true
}

# --- App service -------------------------------------------------------------

module "app" {
  source = "../../modules/ecs-service"

  name         = "${local.name}-app"
  cluster_arn  = aws_ecs_cluster.this.arn
  cluster_name = aws_ecs_cluster.this.name

  # Only used for the very first deployment. See README "First deployment".
  image          = "${aws_ecr_repository.app.repository_url}:${var.initial_image_tag}"
  container_port = var.app_port

  environment = {
    ENVIRONMENT = var.environment
    APP_VERSION = var.initial_image_tag
    PORT        = tostring(var.app_port)
    DB_HOST     = module.db.address
    DB_PORT     = tostring(module.db.port)
    DB_NAME     = module.db.db_name
    DB_SSLMODE  = "require"
  }

  # ECS fetches these from Secrets Manager when a task starts and injects
  # them as env vars. "<arn>:<json-key>::" picks one key out of the secret.
  secrets = {
    DB_USER     = "${module.db.master_user_secret_arn}:username::"
    DB_PASSWORD = "${module.db.master_user_secret_arn}:password::"
  }
  secret_arns = [module.db.master_user_secret_arn]

  subnet_ids         = local.app_subnet_ids
  assign_public_ip   = !var.enable_nat_gateway
  security_group_ids = [aws_security_group.app.id]
  target_group_arn   = module.alb.target_group_arn

  min_count = var.app_min_count
  max_count = var.app_max_count

  # The ALB listener must exist before ECS can register tasks with it.
  depends_on = [module.alb]
}
