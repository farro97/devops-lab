# -----------------------------------------------------------------------------
# ALB MODULE
# A public Application Load Balancer that forwards HTTP traffic to containers.
#
#   Internet --80--> [ALB in public subnets] --app_port--> [ECS tasks]
#
# The target group uses target_type = "ip" because Fargate tasks get their
# own network interface (awsvpc mode). ECS registers and deregisters task
# IPs in the target group automatically during deployments.
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public load balancer: HTTP in from the internet, out to the app only."
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  count = length(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from ${var.allowed_cidrs[count.index]}"
  cidr_ipv4         = var.allowed_cidrs[count.index]
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# The ALB can only talk to the app's security group, on the app port.
resource "aws_vpc_security_group_egress_rule" "to_targets" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To app containers"
  referenced_security_group_id = var.target_security_group_id
  from_port                    = var.target_port
  to_port                      = var.target_port
  ip_protocol                  = "tcp"
}

resource "aws_lb" "this" {
  name               = var.name
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # Rejects requests with malformed headers (protects against request smuggling).
  drop_invalid_header_fields = true

  # Turn on for prod so a stray `terraform destroy` can't delete it.
  enable_deletion_protection = var.deletion_protection

  idle_timeout = 60
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name}-app"
  vpc_id      = var.vpc_id
  port        = var.target_port
  protocol    = "HTTP"
  target_type = "ip"

  # How long the ALB keeps sending in-flight requests to a task that's being
  # stopped. The 300s default makes deployments slow; 30s is plenty here.
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
