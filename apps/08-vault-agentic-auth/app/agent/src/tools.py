"""
tools.py — Agent tool functions.

Two callable tools:
  - bedrock_query(prompt)    → calls AWS Bedrock (Claude), returns text response
                               No API key required — uses the ECS task IAM role.
  - postgres_write(record)   → writes a structured audit record to the Postgres table

Both tools receive credentials at call time; nothing is stored at module level.
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3
import psycopg2

logger = logging.getLogger(__name__)

_BEDROCK_MODEL_ID = os.environ.get(
    "BEDROCK_MODEL_ID",
    "anthropic.claude-3-haiku-20240307-v1:0",
)
_BEDROCK_REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
_POSTGRES_HOST = os.environ.get("POSTGRES_HOST", "localhost")
_POSTGRES_PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
_POSTGRES_DB = os.environ.get("POSTGRES_DB", "agentdb")


def bedrock_query(prompt: str) -> str:
    """Call AWS Bedrock (Claude) and return the generated text.

    Authentication is via the ECS task IAM role — no API key required.
    This is the key Vault story complement: Bedrock uses IAM (zero secrets),
    Postgres uses Vault dynamic credentials (zero static passwords).

    Args:
        prompt: The text prompt to send to the model.

    Returns:
        Generated text string from the model.
    """
    if not prompt or not isinstance(prompt, str):
        raise ValueError("prompt must be a non-empty string")

    client = boto3.client("bedrock-runtime", region_name=_BEDROCK_REGION)

    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 300,
        "messages": [
            {"role": "user", "content": prompt}
        ],
    })

    resp = client.invoke_model(
        modelId=_BEDROCK_MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=body,
    )

    response_body = json.loads(resp["body"].read())

    # Validate response structure before accessing nested keys
    content = response_body.get("content")
    if not isinstance(content, list) or not content:
        raise RuntimeError(
            f"Unexpected Bedrock response structure: {list(response_body.keys())}"
        )
    generated_text: str = content[0].get("text", "")
    logger.info(
        "Bedrock response received — model=%s stop_reason=%s",
        _BEDROCK_MODEL_ID,
        response_body.get("stop_reason"),
    )
    return generated_text


def postgres_write(record: dict, db_username: str, db_password: str) -> None:
    """Write an audit record to the ``agent_audit`` Postgres table.

    The table is created if it does not exist (idempotent DDL).

    Args:
        record:      Dict with string keys/values describing the audit event.
        db_username: Dynamic Postgres username from Vault Database engine.
        db_password: Dynamic Postgres password from Vault Database engine.
    """
    if not isinstance(record, dict):
        raise TypeError("record must be a dict")
    if not db_username or not db_password:
        raise ValueError("db_username and db_password must not be empty")

    conn = psycopg2.connect(
        host=_POSTGRES_HOST,
        port=_POSTGRES_PORT,
        dbname=_POSTGRES_DB,
        user=db_username,
        password=db_password,
        connect_timeout=10,
        sslmode="require",
    )
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS agent_audit (
                        id          SERIAL PRIMARY KEY,
                        ts          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                        agent_name  TEXT NOT NULL,
                        event_type  TEXT NOT NULL,
                        payload     JSONB NOT NULL
                    )
                    """
                )
                cur.execute(
                    """
                    INSERT INTO agent_audit (ts, agent_name, event_type, payload)
                    VALUES (%s, %s, %s, %s)
                    """,
                    (
                        datetime.now(tz=timezone.utc),
                        record.get("agent_name", "app-08-bedrock-agent"),
                        record.get("event_type", "inference"),
                        json.dumps(record),
                    ),
                )
        logger.info(
            "Audit record written to Postgres — event_type=%s", record.get("event_type")
        )
    finally:
        conn.close()
