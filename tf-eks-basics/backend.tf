terraform {
  backend "s3" {
    bucket  = "s3-proops-infras-2026"
    key     = "chau_tv/terraform/eks/terraform.tfstate"
    region  = "ap-southeast-1"   # shared infra bucket is in Singapore
    encrypt = true
    # dynamodb_table omitted: trainee IAM role has no dynamodb:CreateTable
    # permission. Locking is optional for solo use — no concurrent runners.
  }
}
