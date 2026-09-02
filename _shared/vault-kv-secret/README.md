# vault-kv-secret

**Shared Terraform module — enables a Vault KV v2 engine, writes an initial secret, and creates a read-only policy.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Vault Provider](https://img.shields.io/badge/Vault%20Provider-5.11.0-1F6FEB)

## At a Glance

| | |
|---|---|
| **Module path** | `_shared/vault-kv-secret` |
| **Vault Provider** | `hashicorp/vault = 5.11.0` |
| **What it creates** | KV v2 mount, optional initial secret, read-only policy |

## Quick Start

```hcl
module "vault_secret" {
  source = "../../_shared/vault-kv-secret"

  app_name              = "hello-vault-python"
  mount_path            = "apps/hello-python"
  secret_path           = "config"
  policy_name           = "hello-vault-python-read"
  create_initial_secret = true
  secret_data = {
    db_username = "appuser"
    db_password = "changeme"   # rotate this in Vault after first apply
    greeting    = "Hello from Vault!"
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `app_name` | Application name | `string` | — | yes |
| `mount_path` | KV v2 mount path | `string` | `"secret"` | no |
| `secret_path` | Path inside the mount | `string` | — | yes |
| `policy_name` | Vault policy name to create | `string` | — | yes |
| `create_initial_secret` | Write initial secret values | `bool` | `true` | no |
| `secret_data` | Key/value pairs to store (sensitive) | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `mount_path` | Mount path of the KV v2 engine |
| `secret_path` | Full KV path (`mount/data/path`) |
| `policy_name` | Name of the read-only policy |
