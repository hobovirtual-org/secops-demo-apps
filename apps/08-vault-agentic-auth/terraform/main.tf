# ══════════════════════════════════════════════════════════════════════════════
# App 08 — Vault Agentic Auth
# Self-contained: creates its own VPC, ECS cluster, Vault config, and
# Agent Registry entry. No dependencies on any other demo app.
# ══════════════════════════════════════════════════════════════════════════════

# ── Random values ─────────────────────────────────────────────────────────────

resource "random_password" "postgres_vault_role_suffix" {
  length  = 8
  special = false
  upper   = false
}

# ── Networking ────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-public-${count.index + 1}"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${local.name_prefix}-private-${count.index + 1}"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${local.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-rt-private"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security Groups ───────────────────────────────────────────────────────────

# Agent task: egress to Vault (HTTPS) and Postgres sidecar only
resource "aws_security_group" "agent_task" {
  name        = "${local.name_prefix}-agent-task-sg"
  description = "ECS Fargate agent task - egress to Vault and Postgres sidecar"
  vpc_id      = aws_vpc.main.id

  # Vault HTTPS
  egress {
    description = "Vault HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Postgres sidecar (same task, localhost)
  egress {
    description = "Postgres sidecar"
    from_port   = local.postgres_port
    to_port     = local.postgres_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${local.name_prefix}-agent-task-sg"
  }
}

# ── ECR Repository ────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "agent" {
  name                 = "${local.name_prefix}-agent"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# ── IAM — ECS Task Role (used by the agent container) ─────────────────────────

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    sid     = "ECSTasksAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_role" {
  name               = "${local.name_prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = {
    Name = "${local.name_prefix}-task-role"
  }
}

# The task role needs permission to call AWS Bedrock — all other secrets come
# from Vault after JWT authentication. The ECS metadata endpoint JWT requires
# no IAM call.

data "aws_iam_policy_document" "bedrock_invoke" {
  statement {
    sid    = "BedrockInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      "arn:aws:bedrock:${var.aws_region}::foundation-model/${local.bedrock_model_id}",
    ]
  }
}

resource "aws_iam_role_policy" "bedrock_invoke" {
  name   = "bedrock-invoke"
  role   = aws_iam_role.ecs_task_role.id
  policy = data.aws_iam_policy_document.bedrock_invoke.json
}

# ── IAM — ECS Task Execution Role (used by ECS control plane) ────────────────

data "aws_iam_policy_document" "ecs_execution_assume_role" {
  statement {
    sid     = "ECSExecutionAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution_role" {
  name               = "${local.name_prefix}-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_execution_assume_role.json

  tags = {
    Name = "${local.name_prefix}-execution-role"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow the execution role to pull from ECR
data "aws_iam_policy_document" "ecr_pull" {
  statement {
    sid    = "ECRPull"
    effect = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ecr_pull" {
  name   = "ecr-pull"
  role   = aws_iam_role.ecs_execution_role.id
  policy = data.aws_iam_policy_document.ecr_pull.json
}

# ── CloudWatch Log Group ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "agent" {
  name              = "/ecs/${local.name_prefix}/agent"
  retention_in_days = 30
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ── ECS Task Definition ───────────────────────────────────────────────────────
# Two containers:
#   1. agent      — Python agent (reads from Vault, calls watsonx, writes audit)
#   2. postgres   — Lightweight Postgres sidecar (no RDS cost for the demo)

resource "aws_ecs_task_definition" "agent" {
  family                   = "${local.name_prefix}-agent"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "agent"
      image     = local.agent_image
      essential = true

      environment = [
        { name = "VAULT_ADDR", value = var.vault_address },
        { name = "VAULT_NAMESPACE", value = var.vault_namespace },
        { name = "VAULT_JWT_ROLE", value = local.vault_jwt_role },
        { name = "DB_VAULT_ROLE", value = local.vault_db_role },
        { name = "BEDROCK_MODEL_ID", value = local.bedrock_model_id },
        { name = "AWS_DEFAULT_REGION", value = var.aws_region },
        { name = "AGENT_PROMPT", value = var.agent_prompt },
        { name = "AGENT_NAME", value = local.agent_entity_name },
        { name = "POSTGRES_HOST", value = "localhost" },
        { name = "POSTGRES_PORT", value = tostring(local.postgres_port) },
        { name = "POSTGRES_DB", value = local.postgres_db },
      ]

      # No secrets in the task definition — all credentials come from Vault
      secrets = []

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.agent.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "agent"
        }
      }
    },
    {
      name      = "postgres"
      image     = "docker.io/library/postgres:16-alpine"
      essential = false

      environment = [
        { name = "POSTGRES_DB", value = local.postgres_db },
        { name = "POSTGRES_USER", value = "vaultadmin" },
        # The admin password is passed at task launch time via the execution role secret
        # and is used only by the Vault Database engine — not by the agent directly.
        { name = "POSTGRES_PASSWORD", value = var.postgres_admin_password },
        # Allow SSL connections
        { name = "POSTGRES_HOST_AUTH_METHOD", value = "scram-sha-256" },
      ]

      portMappings = [
        {
          containerPort = local.postgres_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.agent.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "postgres"
        }
      }
    }
  ])
}

# ── ECS Service ───────────────────────────────────────────────────────────────
# Runs once (desired_count = 1) — the agent is a one-shot pipeline, not a server.

resource "aws_ecs_service" "agent" {
  name            = "${local.name_prefix}-agent-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.agent.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.agent_task.id]
    assign_public_ip = false
  }

  # Restart on failure
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
}

# ══════════════════════════════════════════════════════════════════════════════
# Vault Resources
# ══════════════════════════════════════════════════════════════════════════════

# ── Database Secrets Engine ───────────────────────────────────────────────────

resource "vault_mount" "database" {
  path        = local.vault_db_mount
  type        = "database"
  description = "Database secrets engine for dynamic Postgres credentials (app-08)"
}

resource "vault_database_secret_backend_connection" "postgres" {
  backend       = vault_mount.database.path
  name          = "agent-postgres"
  allowed_roles = [local.vault_db_role]

  postgresql {
    connection_url = "postgresql://vaultadmin:${var.postgres_admin_password}@localhost:${local.postgres_port}/${local.postgres_db}?sslmode=require"
    # Vault rotates this password after the first connection to prevent
    # static admin credential exposure.
    username_template = "v-agent-{{random 8}}"
  }
}

resource "vault_database_secret_backend_role" "agent_postgres" {
  backend     = vault_mount.database.path
  name        = local.vault_db_role
  db_name     = vault_database_secret_backend_connection.postgres.name
  default_ttl = var.db_creds_ttl
  max_ttl     = var.db_creds_max_ttl
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT SELECT, INSERT ON agent_audit TO \"{{name}}\";",
  ]
  revocation_statements = [
    "REVOKE ALL ON agent_audit FROM \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";",
  ]
}

# ── Vault Policy ──────────────────────────────────────────────────────────────

resource "vault_policy" "ai_agent" {
  name = local.vault_policy_name

  policy = <<-EOT
    # Generate dynamic Postgres credentials
    # (Bedrock access is via IAM role — no Vault secret needed)
    path "${local.vault_db_mount}/creds/${local.vault_db_role}" {
      capabilities = ["read"]
    }

    # Allow token self-renewal
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }

    # Allow token self-lookup
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}

# ── JWT Auth Method ───────────────────────────────────────────────────────────
# auth/jwt is a shared mount managed centrally by vault-config/main.tf.
# This workspace only creates the role within it — no data source needed.

resource "vault_jwt_auth_backend_role" "ecs_agent" {
  backend   = local.vault_jwt_path
  role_name = local.vault_jwt_role
  role_type = "jwt"

  # Bound audience — must match the audience in the ECS task identity token
  bound_audiences = ["vault"]

  # Bind to the ECS task role ARN via the sub claim
  bound_subject = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:assumed-role/${aws_iam_role.ecs_task_role.name}/*"

  # User claim identifies the agent in Vault audit logs
  user_claim = "sub"

  token_policies = [vault_policy.ai_agent.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
  token_type     = "service"
}

# ── Vault Agent Registry (Enterprise) ────────────────────────────────────────
# The Vault Enterprise Agent Registry is surfaced through Identity entities.
# Creating an entity with the agent_type metadata is what the Vault UI reads
# to list and manage registered AI agents.

resource "vault_identity_entity" "ai_agent" {
  name     = local.agent_entity_name
  disabled = false
  policies = [vault_policy.ai_agent.name]

  metadata = {
    agent_type         = "ai"
    agent_name         = local.agent_entity_name
    operational_status = "active"
    app                = "app-08"
    auth_method        = "jwt"
    managed_by         = "terraform"
  }
}
