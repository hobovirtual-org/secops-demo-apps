# ── Vault: KV secret + policy ────────────────────────────────────────────
module "vault_secret" {
  source = "../../../_shared/vault-kv-secret"

  app_name              = local.app_name
  mount_path            = "apps/${local.app_name}"
  secret_path           = "config"
  policy_name           = "${local.app_name}-read"
  create_initial_secret = true
  secret_data = {
    greeting    = "Hello from Vault + Go!"
    db_username = "appuser"
    db_password = "change-me-in-vault"
  }
}

# ── Vault: AWS auth role ──────────────────────────────────────────────────
module "vault_aws_auth" {
  source = "../../../_shared/vault-aws-auth"

  app_name                 = local.app_name
  role_name                = local.app_name
  auth_type                = "iam"
  token_policies           = [module.vault_secret.policy_name]
  bound_iam_principal_arns = [aws_iam_role.app.arn]
}

# ── Networking ────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = { Name = "${local.name_prefix}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name_prefix}-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security group ────────────────────────────────────────────────────────
resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-sg"
  description = "Allow SSH and HTTP for ${local.app_name}"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "HTTP app"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-sg" }
}

# ── IAM role for EC2 (Vault AWS auth) ────────────────────────────────────
resource "aws_iam_role" "app" {
  name = "${local.name_prefix}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Vault AWS auth requires the instance to call sts:GetCallerIdentity
resource "aws_iam_role_policy" "vault_auth" {
  name = "vault-iam-auth"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = "sts:GetCallerIdentity"
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name_prefix}-profile"
  role = aws_iam_role.app.name
}

# ── AMI data source ───────────────────────────────────────────────────────
data "aws_ami" "rhel9" {
  most_recent = true
  owners      = [var.ami_owner_account_id]

  filter {
    name   = "name"
    values = ["hc-base-rhel-9-x86_64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── EC2 instance ──────────────────────────────────────────────────────────
resource "aws_instance" "app" {
  ami                    = data.aws_ami.rhel9.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name
  key_name               = var.existing_key_pair_name

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  user_data = local.user_data

  tags = { Name = "${local.name_prefix}-ec2" }
}
