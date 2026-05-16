resource "aws_eks_cluster" "main" {
  name     = "taskmanager-chau-lab"
  role_arn = "arn:aws:iam::905418181527:role/eksctl-taskmanager-chau-lab-cluster-ServiceRole-YlOrjsFFD65P"
  version  = "1.30"

  vpc_config {
    subnet_ids = [
      "subnet-039519e64a6b21d9e",
      "subnet-00da9444962cea6b6",
      "subnet-05a5876cb43d8060b",
      "subnet-0b05ade4e0a14d18d",
    ]
    security_group_ids      = ["sg-0aa39b8e846959fbf"]
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  lifecycle {
    # eksctl and CloudFormation own the aws:cloudformation/* and
    # alpha.eksctl.io/* tags. Telling Terraform to ignore tags prevents
    # a perpetual diff where Terraform wants to remove those tags.
    ignore_changes = [tags]
  }
}

resource "aws_security_group_rule" "app_port" {
  type      = "ingress"
  from_port = 8080
  to_port   = 8080
  protocol  = "tcp"

  # Allow only traffic originating within the VPC — not from the internet.
  cidr_blocks = ["10.0.0.0/16"]

  # Attach to the cluster security group (auto-created by EKS, its ID is
  # computed after import — no hardcoding needed).
  security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id

  description = "Allow port 8080 from within VPC - api-gateway app traffic"
}
