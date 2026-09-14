"""
vault_auth.py — JWT-based Vault authentication helper for ECS Fargate tasks.

Flow:
  1. Retrieve the ECS task identity JWT from the task metadata v4 endpoint.
  2. POST the JWT to Vault's JWT auth method to obtain a short-lived Vault token.
  3. Provide helpers to read KV-v2 secrets and Database engine credentials.

No static credentials are used at any point.
"""

import json
import logging
import os

import requests

logger = logging.getLogger(__name__)

_VAULT_ADDR = os.environ["VAULT_ADDR"]
_VAULT_NAMESPACE = os.environ.get("VAULT_NAMESPACE", "")
_VAULT_JWT_ROLE = os.environ.get("VAULT_JWT_ROLE", "ai-agent-role")
# ECS task metadata v4 endpoint — injected automatically by ECS
_ECS_META_URI = os.environ.get("ECS_CONTAINER_METADATA_URI_V4", "")

# Requests session — reused for connection pooling; TLS verification always on.
_session = requests.Session()
_session.verify = True


def _base_headers(token: str | None = None) -> dict[str, str]:
    headers: dict[str, str] = {"Content-Type": "application/json"}
    if _VAULT_NAMESPACE:
        headers["X-Vault-Namespace"] = _VAULT_NAMESPACE
    if token:
        headers["X-Vault-Token"] = token
    return headers


def _get_ecs_task_jwt() -> str:
    """Fetch the ECS task identity JWT from the task metadata endpoint.

    Raises RuntimeError if the endpoint is not available (i.e. not running on ECS).
    """
    if not _ECS_META_URI:
        raise RuntimeError(
            "ECS_CONTAINER_METADATA_URI_V4 is not set — "
            "this agent must run inside an ECS Fargate task."
        )
    url = f"{_ECS_META_URI}/task/identity-token"
    resp = _session.get(url, timeout=5)
    resp.raise_for_status()
    jwt = resp.text.strip()
    if not jwt:
        raise RuntimeError("Received empty identity JWT from ECS metadata endpoint.")
    logger.info("Retrieved ECS task identity JWT (length=%d)", len(jwt))
    return jwt


def get_vault_token() -> str:
    """Authenticate to Vault using the ECS task JWT and return a Vault client token.

    The returned token is short-lived (TTL defined by the Vault JWT role).
    """
    jwt = _get_ecs_task_jwt()
    url = f"{_VAULT_ADDR}/v1/auth/jwt/login"
    payload = {"role": _VAULT_JWT_ROLE, "jwt": jwt}
    resp = _session.post(url, json=payload, headers=_base_headers(), timeout=10)
    resp.raise_for_status()
    body = resp.json()
    token = body["auth"]["client_token"]
    ttl = body["auth"].get("lease_duration", "unknown")
    logger.info(
        "Vault JWT auth successful — token TTL=%s, policies=%s",
        ttl,
        body["auth"].get("policies", []),
    )
    return token


def get_kv_secret(token: str, path: str) -> dict:
    """Read a KV-v2 secret. `path` should be the full API path, e.g.
    ``secret/data/agents/app-08/watsonx``.

    Returns the ``data`` dict from the KV-v2 response body.
    """
    url = f"{_VAULT_ADDR}/v1/{path}"
    resp = _session.get(url, headers=_base_headers(token), timeout=10)
    resp.raise_for_status()
    body = resp.json()
    data: dict = body["data"]["data"]
    logger.info("Read KV-v2 secret at path=%s (keys=%s)", path, list(data.keys()))
    return data


def get_dynamic_db_creds(token: str, role: str) -> dict:
    """Generate dynamic Postgres credentials from the Vault Database secrets engine.

    `role` is the Vault database role name, e.g. ``agent-postgres-role``.
    Returns ``{"username": ..., "password": ..., "lease_duration": ...}``.
    """
    url = f"{_VAULT_ADDR}/v1/database/creds/{role}"
    resp = _session.get(url, headers=_base_headers(token), timeout=10)
    resp.raise_for_status()
    body = resp.json()
    creds: dict = body["data"]
    logger.info(
        "Generated dynamic DB creds — username=%s, lease_duration=%s",
        creds.get("username"),
        body.get("lease_duration"),
    )
    return creds
