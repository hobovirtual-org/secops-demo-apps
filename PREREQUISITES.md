# Prerequisites

Everything that must exist **before** you trigger a single Terraform run in this repo.
Follow the sections in order — each layer depends on the one above it.

---

## Layer 1 — HashiCorp Vault (`secops-vault-dev`)

This repo's apps are **consumers** of Vault. The Vault server itself is provisioned by a separate repo:
[`secops-vault-dev`](https://github.com/hobovirtual-org/secops-vault-dev)

### 1.1 — Vault must be running and initialized

```bash
# From secops-vault-dev, check your Vault is up
export VAULT_ADDR=https://vault.christian-renaud.sbx.hashidemos.io
export VAULT_NAMESPACE=admin
export VAULT_TOKEN=<root-or-admin-token>

vault status
# Sealed: false   ← required
```

If Vault is sealed or uninitialized, run the init script in `secops-vault-dev`:

```bash
cd /path/to/secops-vault-dev
./scripts/init-vault.sh
eval "$(./scripts/vault-env.sh)"
```

### 1.2 — Vault Terraform provider token

The Terraform provider in every app uses `VAULT_TOKEN` (set as an HCP Terraform workspace env variable) to configure Vault resources (auth methods, policies, secrets).

**Create a dedicated admin token** — do not use the root token in automation:

```bash
# Create a long-lived token with the admin policy (rotate regularly)
vault token create \
  -display-name="hcp-terraform-demo-apps" \
  -policy="admin" \
  -ttl="720h" \
  -renewable=true
```

Save the `token` value — you will put it in the HCP Terraform variable set in Layer 3.

> [!WARNING]
> Never commit this token to git. It lives only in HCP Terraform as a sensitive env variable.

### 1.3 — Vault AWS auth backend (EC2 apps 01–05)

Each EC2 app's Terraform creates its own auth backend and role automatically via the
`_shared/vault-aws-auth` module. No manual Vault setup is required for the auth method itself.

**However**, Vault needs IAM permissions to call `sts:GetCallerIdentity` to verify the
incoming EC2 login. If Vault is running on EC2 with an IAM role (as deployed by `secops-vault-dev`),
ensure that role has no SCP or permission boundary blocking outbound STS calls.

### 1.4 — Vault Kubernetes auth backend (EKS apps 06–07)

The EKS app Terraform and the Stack configure the Kubernetes auth backend automatically.
No manual steps needed — Terraform handles it.

### 1.5 — Vault AWS secrets engine (App 05 only)

App 05 uses the Vault AWS secrets engine to issue dynamic IAM credentials. For this to work,
Vault's own IAM identity must have permissions to create and delete IAM users:

```bash
# Attach to the Vault EC2 instance role in secops-vault-dev (add to its IAM policy):
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "iam:CreateUser", "iam:DeleteUser",
      "iam:AttachUserPolicy", "iam:DetachUserPolicy",
      "iam:CreateAccessKey", "iam:DeleteAccessKey",
      "iam:PutUserPolicy", "iam:DeleteUserPolicy",
      "iam:ListUserPolicies", "iam:ListAttachedUserPolicies"
    ],
    "Resource": "arn:aws:iam::*:user/vault-*"
  }]
}
```

---

## Layer 2 — AWS Account

### 2.1 — Approved RHEL 9 AMI

Apps 01–05 launch EC2 instances from an approved RHEL 9 base AMI. You need the AWS account ID
that owns that AMI. From `secops-vault-dev`'s `terraform.tfvars`:

```
ami_owner_account_id = "888995627335"
```

Set this same value in every EC2 app workspace.

### 2.2 — EC2 key pair

All EC2 apps accept SSH connections using an existing key pair in your AWS account.
The key pair name from `secops-vault-dev` is:

```
existing_key_pair_name = "linux"
```

Use the same key pair for the demo apps (or create a new one and update accordingly).

### 2.3 — OIDC IAM role for HCP Terraform (EKS apps + Stack)

EKS apps (06, 07) and the `eks-vault-stack` authenticate to AWS using **OIDC dynamic credentials**
instead of long-lived access keys. Create a single IAM role that HCP Terraform assumes:

```bash
# 1. Create the role with the HCP Terraform OIDC trust policy
aws iam create-role \
  --role-name hcp-terraform-oidc-demo \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/app.terraform.io"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "app.terraform.io:aud": "aws.workload.identity"
        },
        "StringLike": {
          "app.terraform.io:sub": "organization:crenaud-org:project:*:workspace:demo-app-*:run_phase:*"
        }
      }
    }]
  }'

# 2. Attach AdministratorAccess for demo purposes
#    (scope this down to least-privilege for production)
aws iam attach-role-policy \
  --role-name hcp-terraform-oidc-demo \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

# 3. Note the role ARN — you will need it in the Stack deployment config
aws iam get-role --role-name hcp-terraform-oidc-demo \
  --query 'Role.Arn' --output text
```

> [!IMPORTANT]
> For EC2 apps (01–05) using standard VCS-driven workspaces, configure dynamic credentials
> directly in HCP Terraform (see Layer 3.3). The OIDC role ARN is the same role.

---

## Layer 3 — HCP Terraform (`crenaud-org`)

### 3.1 — Create a project

In HCP Terraform, create a project called **`demo-apps`** to group all workspaces cleanly.

### 3.2 — Vault connection variable set

Create a variable set named **`vault-demo-connection`**, scoped to the `demo-apps` project:

| Variable | Value | Category | Sensitive |
|---|---|---|---|
| `TF_VAR_vault_address` | `https://vault.christian-renaud.sbx.hashidemos.io` | env | no |
| `TF_VAR_vault_namespace` | `admin` | env | no |
| `VAULT_TOKEN` | *(token from step 1.2)* | env | ✅ yes |
| `VAULT_ADDR` | `https://vault.christian-renaud.sbx.hashidemos.io` | env | no |
| `VAULT_NAMESPACE` | `admin` | env | no |

### 3.3 — AWS dynamic credentials variable set

Create a variable set named **`aws-dynamic-creds-demo`**, scoped to the `demo-apps` project.
Follow the [HCP Terraform dynamic credentials guide](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/aws-configuration):

| Variable | Value | Category | Sensitive |
|---|---|---|---|
| `TFC_AWS_PROVIDER_AUTH` | `true` | env | no |
| `TFC_AWS_RUN_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/hcp-terraform-oidc-demo` | env | no |

### 3.4 — Shared variables variable set

Create a variable set named **`demo-apps-shared`**, scoped to the `demo-apps` project:

| Variable | Value | Category | Sensitive |
|---|---|---|---|
| `TF_VAR_project_name` | `demo` | env | no |
| `TF_VAR_environment` | `dev` | env | no |
| `TF_VAR_aws_region` | `us-east-1` | env | no |
| `TF_VAR_ami_owner_account_id` | `888995627335` | env | no |
| `TF_VAR_existing_key_pair_name` | `linux` | env | no |

### 3.5 — Create workspaces (EC2 apps 01–05)

For each EC2 app, create a **VCS-driven workspace** in the `demo-apps` project:

| Workspace name | Working directory | Variable sets to attach |
|---|---|---|
| `demo-app-01-hello-vault-python` | `apps/01-hello-vault-python-ec2/terraform` | all three above |
| `demo-app-02-hello-vault-go` | `apps/02-hello-vault-go-ec2/terraform` | all three above |
| `demo-app-03-hello-vault-node` | `apps/03-hello-vault-node-ec2/terraform` | all three above |
| `demo-app-04-hello-vault-java` | `apps/04-hello-vault-java-ec2/terraform` | all three above |
| `demo-app-05-vault-dynamic-aws` | `apps/05-vault-dynamic-aws-creds/terraform` | all three above |

Add one **workspace-level** variable to each (these differ per app):

| Workspace | Variable | Value | Category |
|---|---|---|---|
| all EC2 | `TF_VAR_allowed_cidr_blocks` | `["x.x.x.x/32"]` (your IP, HCL type) | terraform |

### 3.6 — EKS apps (06–07): use the Stack instead of workspaces

Apps 06 and 07 each provision a VPC + EKS cluster + Vault configuration + Kubernetes workload.
That is exactly what HCP Terraform Stacks are designed for. **Do not create individual workspaces
for these apps.** Instead:

1. In HCP Terraform, create a **Stack** in the `demo-apps` project.
2. Point it at this repo with working directory `stacks/eks-vault-stack`.
3. Update [`stacks/eks-vault-stack/deployments.tfdeploy.hcl`](stacks/eks-vault-stack/deployments.tfdeploy.hcl)
   with the real `vault_address` and `aws_role_arn` (see Layer 2.3).
4. Upload the Stack configuration:
   ```bash
   cd stacks/eks-vault-stack
   terraform stacks init
   terraform stacks validate
   terraform stacks configuration upload
   ```

> [!NOTE]
> The Stack manages one deployment (`dev`) that covers both the EKS cluster infrastructure
> and the Vault Kubernetes auth configuration in a single orchestrated run.

---

## Layer 4 — Local workstation tools

| Tool | Minimum version | Install | Purpose |
|---|---|---|---|
| Terraform CLI | `>= 1.9.0` | [tfenv](https://github.com/tfutils/tfenv) or direct | EC2 app Terraform |
| Terraform CLI | `>= 1.14.5` | Same — use `.terraform-version` | Stacks CLI |
| AWS CLI | `>= 2.0` | `brew install awscli` | EKS kubeconfig, IAM |
| kubectl | `>= 1.29` | `brew install kubectl` | EKS workloads |
| Helm | `>= 3.0` | `brew install helm` | Vault Agent Injector |
| vault CLI | any | `brew install vault` | smoke-testing |

Verify:

```bash
terraform version      # >= 1.14.5
aws --version          # >= 2.0
kubectl version --client
helm version
vault version
```

---

## Validation checklist

Run through this before triggering any app run:

- [ ] `vault status` returns `Sealed: false` at `https://vault.christian-renaud.sbx.hashidemos.io`
- [ ] `VAULT_TOKEN` is set and `vault token lookup` shows a valid token
- [ ] AMI owner account `888995627335` has a matching RHEL 9 AMI in `us-east-1`
- [ ] EC2 key pair `linux` exists in the target AWS account and region
- [ ] HCP Terraform org `crenaud-org` has the three variable sets created and attached to `demo-apps` project
- [ ] OIDC IAM role `hcp-terraform-oidc-demo` exists and trusts `app.terraform.io`
- [ ] `stacks/eks-vault-stack/deployments.tfdeploy.hcl` has real values (not `vault.example.com`)
- [ ] App 01 workspace is created and all variable sets are attached
- [ ] App 01 plan completes successfully in HCP Terraform

---

## Deployment order

Start simple — validate the full secret flow before deploying EKS.

```
1. App 01 (Python/EC2)   ← validates Vault + AWS IAM auth + KV v2 end-to-end
2. App 05 (Dynamic creds) ← validates Vault AWS secrets engine
3. App 06 (EKS/K8s auth) ← validates EKS + Vault Agent Injector
4. App 07 (MERN)         ← most complex; builds on App 06 pattern
5. Stack                  ← deploy after Apps 06/07 are validated individually
```
