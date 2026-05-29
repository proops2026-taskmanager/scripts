output "instance_id" {
  description = "EC2 instance ID — verify this in AWS Console after apply"
  value       = module.app_server.id
}

output "instance_name" {
  description = "Resource name — must match Day 27 naming convention"
  value       = local.name
}

output "public_ip" {
  description = "Public IP (null if no public subnet assigned)"
  value       = module.app_server.public_ip
}
