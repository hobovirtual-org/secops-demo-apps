# vault-aws-auth

**Shared Terraform module — enables the Vault AWS auth method and creates a named role.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Vault Provider](https://img.shields.io/badge/Vault%20Provider-5.11.0-1F6FEB)

## At a Glance

| | |
|---|---|
| **Module path** | `_shared/vault-aws-auth` |
| **Vault Provider** | `hashicorp/vault = 5.11.0` |
| **Auth types** | `iam` (recommended), `ec2` |
| **What it creates** | AWS auth backend mount, AWS auth client config, AWS auth role |

## Quick Start

```hcl
module "vault_aws_auth" {
  source = "../../_shared/vault-aws-auth"

  app_name         = "hello-vault-python"
  role_name        = "hello-vault-python"
  auth_type        = "iam"
  token_policies   = ["hello-vault-python-read"]
  bound_iam_principal_arns = [aws_iam_role.app.arn]
}
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `app_name` | Application name (used in descriptions) | `string` | — | yes |
| `auth_path` | AWS auth mount path | `string` | `"aws"` | no |
| `role_name` | Vault role name | `string` | — | yes |
| `auth_type` | `iam` or `ec2` | `string` | `"iam"` | no |
| `bound_iam_principal_arns` | IAM role ARNs allowed to auth (iam type) | `list(string)` | `[]` | no |
| `bound_iam_instance_profile_arns` | Instance profile ARNs (ec2 type) | `list(string)` | `[]` | no |
| `token_policies` | Vault policies attached to issued tokens | `list(string)` | — | yes |
| `token_ttl` | Token TTL in seconds | `number` | `3600` | no |
| `token_max_ttl` | Token max TTL in seconds | `number` | `86400` | no |

## Outputs

| Name | Description |
|---|---|
| `auth_path` | Mount path of the AWS auth backend |
| `role_name` | Name of the Vault AWS auth role |
| `role_id` | Internal Vault ID of the role |
