output "dns_name" {
  description = "Public hostname of the load balancer."
  value       = aws_lb.this.dns_name
}

output "zone_id" {
  description = "Hosted zone ID, for a Route 53 alias record later."
  value       = aws_lb.this.zone_id
}

output "arn" {
  value = aws_lb.this.arn
}

output "arn_suffix" {
  description = "Used as the LoadBalancer dimension in CloudWatch metrics and alarms."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "target_group_arn_suffix" {
  description = "Used as the TargetGroup dimension in CloudWatch metrics and alarms."
  value       = aws_lb_target_group.app.arn_suffix
}

output "security_group_id" {
  value = aws_security_group.alb.id
}
