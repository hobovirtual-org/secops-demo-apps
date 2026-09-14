"""
tools.py — Agent tool functions.

Two callable tools:
  - watsonx_query(prompt)    → calls watsonx.ai Inference API, returns text response
  - postgres_write(record)   → writes a structured audit record to the Postgres table

Both tools receive credentials at call time; nothing is stored at module level.
"""

import json
import logging
import os
from datetime import datetime, timezone

import psycopg2
import requests

logger = logging.getLogger(__name__)

_WATSONX_API_URL = os.environ.get(
    "WATSONX_API_URL",
    "https://us-south.ml.cloud.ibm.com/ml/v1/text/generation?version=2023-05-29",
)
_WATSONX_PROJECT_ID = os.environ.get("WATSONX_PROJECT_ID", "")
_POSTGRES_HOST = os.environ.get("POSTGRES_HOST", "localhost")
_POSTGRES_PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
_POSTGRES_DB = os.environ.get("POSTGRES_DB", "agentdb")

_session = requests.Session()
_session.verify = True  # TLS verification always enabled


def watsonx_query(prompt: str, api_key: str) -> str:
    """Call the watsonx.ai text generation API and return the generated text.

    Args:
        prompt:  The text prompt to send to the model.
        api_key: Short-lived watsonx API key retrieved from Vault KV-v2.

    Returns:
        Generated text string from the model.
    """
    if not prompt or not isinstance(prompt, str):
        raise ValueError("prompt must be a non-empty string")
    if not api_key:
        raise ValueError("api_key must not be empty")

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }
    payload = {
        "model_id": "ibm/granite-13b-chat-v2",
        "input": prompt,
        "parameters": {
            "decoding_method": "greedy",
            "max_new_tokens": 300,
            "min_new_tokens": 10,
        },
        "project_id": _WATSONX_PROJECT_ID,
    }
    resp = _session.post(_WATSONX_API_URL, json=payload, headers=headers, timeout=30)
    resp.raise_for_status()
    body = resp.json()

    # Validate response structure before accessing nested keys
    results = body.get("results")
    if not isinstance(results, list) or not results:
        raise RuntimeError(f"Unexpected watsonx response structure: {list(body.keys())}")
    generated_text: str = results[0].get("generated_text", "")
    logger.info(
        "watsonx.ai response received — tokens_generated=%s",
        results[0].get("generated_token_count"),
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
                        record.get("agent_name", "app-08-watsonx-agent"),
                        record.get("event_type", "inference"),
                        json.dumps(record),
                    ),
                )
        logger.info(
            "Audit record written to Postgres — event_type=%s", record.get("event_type")
        )
    finally:
        conn.close()
