"""
agent.py — App-08 Vault Agentic Auth demo agent.

Demonstrates the full Vault Agentic IAM pipeline:
  1. Authenticate to Vault using an ECS task identity JWT (no static secrets).
  2. Vault validates via JWT auth method and checks the Agent Registry entity.
  3. Fetch a short-lived watsonx API key from Vault KV-v2.
  4. Generate dynamic Postgres credentials from the Vault Database secrets engine.
  5. Call watsonx.ai with a prompt and write a structured audit record to Postgres.
  6. Credentials expire automatically — nothing is persisted.
"""

import json
import logging
import os
import sys

from vault_auth import get_dynamic_db_creds, get_kv_secret, get_vault_token
from tools import postgres_write, watsonx_query

# ── Logging — structured JSON, no sensitive data ─────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format='{"ts": "%(asctime)s", "level": "%(levelname)s", "logger": "%(name)s", "msg": %(message)s}',
    stream=sys.stdout,
)
logger = logging.getLogger("agent")

# ── Configuration from environment variables — no hardcoded values ───────────

VAULT_ADDR = os.environ["VAULT_ADDR"]
WATSONX_KV_PATH = os.environ.get(
    "WATSONX_KV_PATH", "secret/data/agents/app-08/watsonx"
)
DB_VAULT_ROLE = os.environ.get("DB_VAULT_ROLE", "agent-postgres-role")
AGENT_PROMPT = os.environ.get(
    "AGENT_PROMPT",
    "Summarize the zero-trust security principles in 3 bullet points.",
)
AGENT_NAME = os.environ.get("AGENT_NAME", "app-08-watsonx-agent")


def run() -> None:
    """Execute the agentic pipeline end-to-end."""

    logger.info('"Starting Vault agentic auth pipeline"')

    # ── Step 1: Authenticate to Vault via ECS task JWT ────────────────────────
    logger.info('"Step 1: Authenticating to Vault via JWT auth method"')
    vault_token = get_vault_token()
    logger.info('"Vault token acquired — zero static credentials used"')

    # ── Step 2: Fetch watsonx API key from KV-v2 ──────────────────────────────
    logger.info('"Step 2: Reading watsonx API key from Vault KV-v2 at %s"', WATSONX_KV_PATH)
    kv_data = get_kv_secret(vault_token, WATSONX_KV_PATH)
    watsonx_api_key = kv_data.get("api_key")
    if not watsonx_api_key:
        raise RuntimeError(
            f"Expected key 'api_key' not found in KV secret at {WATSONX_KV_PATH}"
        )
    logger.info('"watsonx API key retrieved (length=%d)"', len(watsonx_api_key))

    # ── Step 3: Generate dynamic Postgres credentials ─────────────────────────
    logger.info(
        '"Step 3: Generating dynamic Postgres credentials from Vault Database engine (role=%s)"',
        DB_VAULT_ROLE,
    )
    db_creds = get_dynamic_db_creds(vault_token, DB_VAULT_ROLE)
    db_username = db_creds["username"]
    db_password = db_creds["password"]
    logger.info('"Dynamic DB creds issued — username=%s"', db_username)

    # ── Step 4: Call watsonx.ai ───────────────────────────────────────────────
    logger.info('"Step 4: Calling watsonx.ai — prompt=%s"', json.dumps(AGENT_PROMPT))
    response_text = watsonx_query(AGENT_PROMPT, watsonx_api_key)
    logger.info('"watsonx.ai response received"')
    print("\n─── watsonx.ai Response ─────────────────────────────────────────────")
    print(response_text)
    print("─────────────────────────────────────────────────────────────────────\n")

    # ── Step 5: Write audit record to Postgres ────────────────────────────────
    logger.info('"Step 5: Writing audit record to Postgres"')
    audit_record = {
        "agent_name": AGENT_NAME,
        "event_type": "inference",
        "vault_auth_method": "jwt",
        "secret_engine": "kv-v2",
        "db_engine": "database",
        "prompt": AGENT_PROMPT,
        "response_summary": response_text[:200],
        "hardcoded_secrets": False,
    }
    postgres_write(audit_record, db_username, db_password)
    logger.info('"Audit record written — pipeline complete"')

    # ── Step 6: Credentials expire automatically ──────────────────────────────
    logger.info(
        '"Step 6: Credentials are ephemeral — KV lease and DB TTL will expire automatically"'
    )
    logger.info('"Pipeline complete — zero secrets persist"')


if __name__ == "__main__":
    run()
