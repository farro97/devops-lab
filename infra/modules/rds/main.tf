# -----------------------------------------------------------------------------
# RDS POSTGRES MODULE
# A private Postgres database. Nothing on the internet can reach it: it lives
# in private subnets and its security group only accepts the app.
#
# Password handling: `manage_master_user_password = true` makes RDS generate
# the password and store it in AWS Secrets Manager. The password never
# appears in Terraform code, variables or plan output. (It also doesn't end
# up in the state file, unlike the older `password = ...` argument.)
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids

  tags = { Name = var.name }
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "Postgres. Inbound 5432 from the app security group only."
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "from_app" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from app"
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# No egress rules: the database never needs to start outbound connections.

# Create the log group ourselves so we control retention. If RDS creates it,
# logs are kept forever (and you pay for that storage forever).
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/instance/${var.name}/postgresql"
  retention_in_days = var.log_retention_days
}

resource "aws_db_instance" "this" {
  identifier = var.name

  engine         = "postgres"
  engine_version = var.engine_version # major version only; AWS picks the latest minor
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage # storage autoscaling ceiling
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.username

  # RDS creates and stores the password in Secrets Manager.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period = var.backup_retention_days
  backup_window           = "18:00-19:00" # UTC = 2-3am Singapore time
  maintenance_window      = "sun:19:00-sun:20:00"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately

  enabled_cloudwatch_logs_exports = ["postgresql"]

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final"

  depends_on = [aws_cloudwatch_log_group.postgresql]
}
