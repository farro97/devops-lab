# -----------------------------------------------------------------------------
# ECS FARGATE SERVICE MODULE
# Runs a container on Fargate behind a load balancer.
#
# The pieces:
#   - Log group          where container stdout/stderr goes
#   - Execution role     used BY ECS to pull the image, read secrets, write logs
#   - Task role          used BY YOUR APP CODE to call AWS APIs
#   - Task definition    "what to run": image, CPU/memory, env vars, secrets
#   - Service            "keep N copies running, register them in the ALB"
#   - Auto scaling       add/remove tasks based on CPU
#
# WHO OWNS THE IMAGE TAG?
# Terraform creates the first task definition. After that, the app pipeline
# (.github/workflows/app.yml) registers a new task definition revision for
# every release and points the service at it. So the service ignores
# changes to `task_definition`, otherwise every `terraform apply` would roll
# the app back to the image Terraform knows about.
# -----------------------------------------------------------------------------

data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  container_name = "app"

  environment = [for k, v in var.environment : { name = k, value = v }]
  secrets     = [for k, v in var.secrets : { name = k, valueFrom = v }]

  # ECS Exec (shell into a running container) can't work with a read-only
  # root filesystem, so we only lock the filesystem when Exec is off.
  read_only_root_fs = !var.enable_execute_command
}

# --- Logs --------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
}

# --- IAM: execution role (used by ECS itself) --------------------------------

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  # Naming convention matters: the bootstrap deploy role may only pass
  # roles named "<project>-*-ecs-*" to ECS.
  name               = "${var.name}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow ECS to read exactly the secrets this task needs, and nothing else.
data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0

  name   = "read-app-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# --- IAM: task role (used by your app code) ----------------------------------

resource "aws_iam_role" "task" {
  name               = "${var.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

# ECS Exec talks to the container through SSM Session Manager.
data "aws_iam_policy_document" "task_exec" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_exec" {
  count = var.enable_execute_command ? 1 : 0

  name   = "ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec.json
}

# --- Task definition ---------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.image
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      environment = local.environment
      secrets     = local.secrets

      readonlyRootFilesystem = local.read_only_root_fs

      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:${var.container_port}${var.health_check_path}', timeout=3)\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "app"
        }
      }
    }
  ])
}

# --- Service -----------------------------------------------------------------

resource "aws_ecs_service" "app" {
  name             = var.name
  cluster          = var.cluster_arn
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.min_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # Rolling deployment: start new tasks first (up to 200%), then stop old ones,
  # never dropping below 100% healthy.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # If new tasks keep failing, ECS stops the deployment and rolls back to the
  # last working version automatically.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Give a new container time to start before ALB health checks count.
  health_check_grace_period_seconds = 30

  lifecycle {
    # See "WHO OWNS THE IMAGE TAG?" at the top of this file.
    # desired_count is owned by auto scaling once the service exists.
    ignore_changes = [task_definition, desired_count]
  }
}

# --- Auto scaling ------------------------------------------------------------

resource "aws_appautoscaling_target" "app" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.app.name}"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  resource_id        = aws_appautoscaling_target.app.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
