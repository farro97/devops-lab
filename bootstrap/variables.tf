variable "region" {
  description = "AWS region for the state bucket and IAM resources."
  type        = string
  default     = "ap-southeast-1" # Singapore
}

variable "project" {
  description = "Short project name, used as a prefix for resource names. Lowercase letters, numbers and hyphens only."
  type        = string
  default     = "devops-lab"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.project))
    error_message = "Use 3-20 lowercase letters, numbers or hyphens."
  }
}

variable "github_owner" {
  description = "Your GitHub username or organization (e.g. \"octocat\")."
  type        = string
}

variable "github_repo" {
  description = "The name of the GitHub repo that will hold this code (e.g. \"devops-lab\")."
  type        = string
}

variable "github_owner_id" {
  description = "Numeric ID of your GitHub account. Find it at https://api.github.com/users/<username> (the \"id\" field)."
  type        = string
  default     = ""
}

variable "github_repo_id" {
  description = "Numeric ID of the repo. Find it at https://api.github.com/repos/<owner>/<repo> (the \"id\" field)."
  type        = string
  default     = ""
}
