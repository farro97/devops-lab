variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project" {
  type    = string
  default = "devops-lab"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "enable_nat_gateway" {
  description = <<-EOT
    false (default): app tasks run in public subnets with a public IP. No NAT cost.
    true: app tasks run in private subnets behind a NAT Gateway (production
    pattern, roughly USD 1+/day extra). The database is always private either way.
  EOT
  type        = bool
  default     = false
}

variable "app_port" {
  description = "Port your container listens on."
  type        = number
  default     = 8000
}

variable "initial_image_tag" {
  description = "Image tag for the FIRST deployment only. Push this tag to ECR before applying (see README). After that, the app pipeline deploys new versions."
  type        = string
  default     = "initial"
}

variable "allowed_cidrs" {
  description = "Who can reach the load balancer. Use [\"<your-ip>/32\"] to keep the app private to you."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "app_min_count" {
  type    = number
  default = 1
}

variable "app_max_count" {
  type    = number
  default = 2
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "container_insights" {
  description = "ECS Container Insights metrics (extra CloudWatch cost). Leave off until Phase 5."
  type        = bool
  default     = false
}
