# Security Policy

## Reporting a vulnerability

Open a private security advisory on this repository. Do not open a public issue.

## Required GitHub settings

- Enable branch protection on `main`
- Require pull request reviews before merge
- Require status checks to pass before merge
- Enable secret scanning and push protection
- Enable Dependabot alerts and security updates

## HCP Terraform expectations

- All Terraform state is stored in HCP Terraform — never locally or in S3
- Use dynamic AWS credentials (OIDC) — never long-lived static keys
- Mark all sensitive Terraform variables as `sensitive` in the workspace
- Use Vault variable sets to share `VAULT_ADDR` and auth credentials across workspaces

## Secrets in applications

- Applications **never** hold static Vault tokens — they use AWS IAM or Kubernetes auth
- Secrets are injected at runtime by Vault Agent or the Vault SDK
- `.env` files are in `.gitignore` — never commit them
- `.secrets/` directories are in `.gitignore` — never commit them

## Container images

- All base images must come from `registry.redhat.io` (UBI minimal variants preferred)
- Never run containers as root (`USER 1001` or equivalent is required)
- Read-only root filesystem where possible
