output "app_url" {
  description = "Open this in a browser once the service is healthy."
  value       = "http://${module.alb.dns_name}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "ecr_repository_url" {
  description = "docker tag/push target, e.g. <url>:v1"
  value       = aws_ecr_repository.app.repository_url
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  value = module.app.service_name
}

output "task_definition_family" {
  value = module.app.task_definition_family
}

output "app_log_group" {
  description = "CloudWatch log group for the app. Tail it with: aws logs tail <name> --follow"
  value       = module.app.log_group_name
}

output "db_address" {
  value = module.db.address
}

output "db_secret_arn" {
  description = "Secrets Manager secret holding the DB username and password."
  value       = module.db.master_user_secret_arn
}
