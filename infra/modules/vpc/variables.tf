variable "name" {
  description = "Name prefix for all VPC resources."
  type        = string
}

variable "cidr_block" {
  description = "IP range for the whole VPC. Must be a /16 for this module's subnet maths."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr_block, 0)) && endswith(var.cidr_block, "/16")
    error_message = "cidr_block must be a valid /16, e.g. 10.0.0.0/16."
  }
}

variable "az_count" {
  description = "How many availability zones to spread subnets across (2 or 3)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "enable_nat_gateway" {
  description = "Create NAT Gateway(s) so private subnets can reach the internet. Costs roughly USD 1+/day each, so leave off until you need it."
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "true = one shared NAT (cheap, fine for dev). false = one per AZ (resilient, for prod)."
  type        = bool
  default     = true
}
