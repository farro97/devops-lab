variable "name" {
  description = "Identifier for the DB instance and related resources."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets in at least two AZs (RDS requires two, even for single-AZ)."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect on 5432 (e.g. the app)."
  type        = list(string)
}

variable "engine_version" {
  type    = string
  default = "17"
}

variable "instance_class" {
  description = "db.t4g.micro is the smallest/cheapest Graviton class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "GB of storage. 20 is the minimum for gp3."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GB. Set equal to allocated_storage to disable."
  type        = number
  default     = 50
}

variable "db_name" {
  type    = string
  default = "app"
}

variable "username" {
  type    = string
  default = "app_admin"
}

variable "multi_az" {
  description = "Standby copy in a second AZ with automatic failover. Doubles the cost. Use in prod."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  type    = number
  default = 1
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "apply_immediately" {
  description = "Apply changes now instead of waiting for the maintenance window. Fine for dev; false for prod."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "skip_final_snapshot" {
  description = "true = no snapshot on destroy (lab). false = keep a final snapshot (prod)."
  type        = bool
  default     = true
}
