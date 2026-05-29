locals {
  name = "proops-${var.project}-${var.environment}-ec2-euc1-app-server"

  # Day 27 required tags — applied to every resource in this env
  tags = {
    Name             = local.name
    Project          = var.project
    Environment      = var.environment
    ResponsibleParty = var.responsible_party
    Owner            = var.owner
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

module "app_server" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.6"

  name          = local.name
  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type
  key_name      = var.key_name

  tags = local.tags
}
