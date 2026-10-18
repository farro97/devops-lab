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
  description = "NAT Gateways cost money every hour. Keep false until private workloads need internet access."
  type        = bool
  default     = false
}

variable "app_port" {
  description = "Port your container listens on."
  type        = number
  default     = 8001
}
