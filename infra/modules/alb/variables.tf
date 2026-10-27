variable "name" {
  description = "Name prefix. Must be 26 characters or less (ALB and target group names are limited to 32)."
  type        = string

  validation {
    condition     = length(var.name) <= 26
    error_message = "name must be 26 characters or less."
  }
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "At least two public subnets in different AZs."
  type        = list(string)
}

variable "target_port" {
  description = "Port the containers listen on."
  type        = number
}

variable "target_security_group_id" {
  description = "Security group of the containers. The ALB is only allowed to send traffic there."
  type        = string
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "allowed_cidrs" {
  description = "Who may reach the load balancer. Narrow this to your own IP (x.x.x.x/32) to keep the app private."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "deletion_protection" {
  type    = bool
  default = false
}
