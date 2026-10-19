output "eks_cluster_name" {
  description = "Name of the provisioned EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.main.endpoint
}

output "ecr_repository_url" {
  description = "ECR repository URL for the Django application image"
  value       = aws_ecr_repository.django_app.repository_url
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port)"
  value       = aws_db_instance.postgres.endpoint
}

output "rds_address" {
  description = "RDS PostgreSQL hostname"
  value       = aws_db_instance.postgres.address
}

output "kms_key_arn" {
  description = "ARN of the AWS KMS key used by SOPS and helm-secrets"
  value       = aws_kms_key.helm_secrets.arn
}
