variable "name" {
  description = "Service name; also used as the task definition family and IAM role prefix."
  type        = string
}

variable "cluster_arn" {
  type = string
}

variable "cluster_name" {
  description = "Needed for the auto scaling resource ID."
  type        = string
}

variable "image" {
  description = "Initial container image (repo URL + tag). Later releases are deployed by the app pipeline."
  type        = string
}

variable "container_port" {
  type = number
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "cpu" {
  description = "Task CPU units. 256 = 0.25 vCPU (the smallest Fargate size)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task memory in MiB. 512 is the smallest allowed with 256 CPU."
  type        = number
  default     = 512
}

variable "cpu_architecture" {
  description = "X86_64 matches images built on GitHub's default runners. ARM64 (Graviton) is ~20% cheaper but needs an arm64 image."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "environment" {
  description = "Plain environment variables for the container."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Env var name => Secrets Manager reference. Use \"<secret-arn>:<json-key>::\" to pick one key from a JSON secret."
  type        = map(string)
  default     = {}
}

variable "secret_arns" {
  description = "ARNs of the secrets the task may read (without the :key:: suffix)."
  type        = list(string)
  default     = []
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "assign_public_ip" {
  description = "Tasks in public subnets need a public IP to pull images. Tasks in private subnets (behind NAT) don't."
  type        = bool
  default     = false
}

variable "target_group_arn" {
  type = string
}

variable "min_count" {
  type    = number
  default = 1
}

variable "max_count" {
  type    = number
  default = 2
}

variable "cpu_target_percent" {
  description = "Auto scaling adds tasks when average CPU goes above this."
  type        = number
  default     = 60
}

variable "enable_execute_command" {
  description = "Allow `aws ecs execute-command` to open a shell in running containers (great for debugging)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  type    = number
  default = 7
}
