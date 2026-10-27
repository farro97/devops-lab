# -----------------------------------------------------------------------------
# Security groups: who may talk to whom
#
#   Internet --80-->  ALB SG  --app_port-->  App SG  --5432-->  DB SG
#
# Each hop only allows the previous hop's security group, not IP ranges.
# The ALB and DB security groups live in their modules; the app one is here
# because both of those modules need to reference it.
# -----------------------------------------------------------------------------

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "App containers. Inbound on the app port from the load balancer only."
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${local.name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "App port from the load balancer"
  referenced_security_group_id = module.alb.security_group_id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

# Outbound is needed to pull images from ECR, read Secrets Manager, write
# CloudWatch Logs and reach the database.
resource "aws_vpc_security_group_egress_rule" "app_all_out" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound to anywhere (pull images, call AWS APIs, database)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
