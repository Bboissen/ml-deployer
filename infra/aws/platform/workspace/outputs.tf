output "workspace_platform" {
  value = {
    aws_account_id    = var.aws_account_id
    aws_region        = var.aws_region
    subnet_id         = aws_subnet.runner.id
    security_group_id = aws_security_group.runner.id
    deployer_role_arn = aws_iam_role.deployer.arn
    state_bucket_arn  = var.state_bucket_arn
  }
  depends_on = [aws_route_table_association.runner, aws_iam_role_policy.deployer]
}
