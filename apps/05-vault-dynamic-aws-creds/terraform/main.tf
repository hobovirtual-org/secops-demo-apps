# ── Vault: AWS secrets engine (dynamic credentials) ───────────────────────
resource "vault_aws_secret_backend" "main" {
  path        = "aws/dynamic/${local.app_name}"
  description = "AWS secrets engine for ${local.app_name}"
  # Vault uses its own IAM role (configured server-side) to create IAM users
}

resource "vault_aws_secret_backend_role" "demo" {
  backend         = vault_aws_secret_backend.main.path
  name            = "${local.app_name}-s3-reader"
  credential_type = "iam_user"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = "*"
    }]
  })
}

# ── Vault: policy to call the dynamic creds endpoint ─────────────────────
resource "vault_policy" "dynamic_aws" {
  name = "${local.app_name}-dynamic-creds"

  policy = <<-POLICY
    path "${vault_aws_secret_backend.main.path}/creds/${vault_aws_secret_backend_role.demo.name}" {
      capabilities = ["read"]
    }
  POLICY
}

# ── Vault: AWS auth for the EC2 instance ─────────────────────────────────
resource "vault_auth_backend" "aws" {
  type = "aws"
  path = "aws/${local.app_name}"
}

resource "vault_aws_auth_backend_role" "app" {
  backend                  = vault_auth_backend.aws.path
  role                     = local.app_name
  auth_type                = "iam"
  bound_iam_principal_arns = [aws_iam_role.app.arn]
  token_policies           = [vault_policy.dynamic_aws.name]
  token_ttl                = 3600
  token_max_ttl            = 86400
}

# ── Networking ────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"
  tags                    = { Name = "${local.name_prefix}-public" }
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

# ── IAM role ──────────────────────────────────────────────────────────────
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
  tags      = { Name = "${local.name_prefix}-ec2" }
}
