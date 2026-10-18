output "state_bucket" {
  description = "Put this in envs/dev/backend.hcl as `bucket`."
  value       = aws_s3_bucket.tfstate.bucket
}

output "github_plan_role_arn" {
  description = "Add as GitHub repo variable AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.github_plan.arn
}

output "github_apply_role_arn" {
  description = "Add as GitHub repo variable AWS_APPLY_ROLE_ARN."
  value       = aws_iam_role.github_apply.arn
}
