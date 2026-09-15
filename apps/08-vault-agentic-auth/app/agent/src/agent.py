"""
agent.py — App-08 Vault Agentic Auth demo agent.

Demonstrates the full Vault Agentic IAM pipeline:
  1. Authenticate to Vault using an ECS task identity JWT (no static secrets).
  2. Vault validates via JWT auth method and checks the Agent Registry entity.
  3. Generate dynamic Postgres credentials from the Vault Database secrets engine.
  4. Call AWS Bedrock (Claude) via the ECS task IAM role — no API key anywhere.
  5. Write a structured audit record to Postgres using the ephemeral credentials.
  6. Credentials expire automatically — nothing is persisted.

The story: Bedrock auth = IAM (zero secrets). Postgres auth = Vault dynamic
credentials (zero static passwords). Neither path has a hardcoded secret.
"""

import json
import logging
import os
import sys

from vault_auth import get_dynamic_db_creds, get_vault_token
from tools import bedrock_query, postgres_write

# ── Logging — structured JSON, no sensitive data ─────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format='{"ts": "%(asctime)s", "level": "%(levelname)s", "logger": "%(name)s", "msg": %(message)s}',
    stream=sys.stdout,
)
logger = logging.getLogger("agent")

# ── Configuration from environment variables — no hardcoded values ───────────

VAULT_ADDR = os.environ["VAULT_ADDR"]
DB_VAULT_ROLE = os.environ.get("DB_VAULT_ROLE", "agent-postgres-role")
AGENT_PROMPT = os.environ.get(
    "AGENT_PROMPT",
    "Summarize the zero-trust security principles in 3 bullet points.",
)
AGENT_NAME = os.environ.get("AGENT_NAME", "app-08-bedrock-agent")


def run() -> None:
    """Execute the agentic pipeline end-to-end."""

    logger.info('"Starting Vault agentic auth pipeline"')

    # ── Step 1: Authenticate to Vault via ECS task JWT ────────────────────────
    logger.info('"Step 1: Authenticating to Vault via JWT auth method"')
    vault_token = get_vault_token()
    logger.info('"Vault token acquired — zero static credentials used"')

    # ── Step 2: Generate dynamic Postgres credentials ─────────────────────────
    logger.info(
        '"Step 2: Generating dynamic Postgres credentials from Vault Database engine (role=%s)"',
        DB_VAULT_ROLE,
    )
    db_creds = get_dynamic_db_creds(vault_token, DB_VAULT_ROLE)
    db_username = db_creds["username"]
    db_password = db_creds["password"]
    logger.info('"Dynamic DB creds issued — username=%s"', db_username)

    # ── Step 3: Call AWS Bedrock via ECS task IAM role (no API key) ───────────
    logger.info('"Step 3: Calling AWS Bedrock (Claude) via ECS task IAM role — prompt=%s"', json.dumps(AGENT_PROMPT))
    response_text = bedrock_query(AGENT_PROMPT)
    logger.info('"Bedrock response received"')
    print("\n─── AWS Bedrock (Claude) Response ───────────────────────────────────")
    print(response_text)
    print("─────────────────────────────────────────────────────────────────────\n")

    # ── Step 4: Write audit record to Postgres ────────────────────────────────
    logger.info('"Step 4: Writing audit record to Postgres"')
    audit_record = {
        "agent_name": AGENT_NAME,
        "event_type": "inference",
        "vault_auth_method": "jwt",
        "llm_auth_method": "iam_role",
        "db_engine": "database",
        "prompt": AGENT_PROMPT,
        "response_summary": response_text[:200],
        "hardcoded_secrets": False,
    }
    postgres_write(audit_record, db_username, db_password)
    logger.info('"Audit record written — pipeline complete"')

    # ── Step 5: Credentials expire automatically ──────────────────────────────
    logger.info(
        '"Step 5: Credentials are ephemeral — DB TTL will expire automatically"'
    )
    logger.info('"Pipeline complete — zero secrets persist"')


if __name__ == "__main__":
    run()
