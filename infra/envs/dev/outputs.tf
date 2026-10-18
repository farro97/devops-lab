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
