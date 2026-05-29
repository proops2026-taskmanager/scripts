variable "region" {
  description = "AWS region for EC2 resources"
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Project shortcode — used in resource name + tags"
  type        = string
  default     = "taskmanager"
}

variable "environment" {
  description = "Environment: dev / test / prod"
  type        = string
  default     = "dev"
}

variable "responsible_party" {
  description = "Team email for the ResponsibleParty tag"
  type        = string
  default     = "vanchautran11ece@gmail.com"
}

variable "owner" {
  description = "Trainee ID for the Owner tag"
  type        = string
  default     = "chau11ece"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "EC2 key pair for SSH (null = no SSH access)"
  type        = string
  default     = "chautv-public-ec2-kp"
}
