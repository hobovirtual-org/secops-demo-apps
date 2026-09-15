"""
agent.py — App-08: Vault Agentic Auth demo

Story (for security team audience):
  An AI agent running in GitHub Actions authenticates to Vault using a
  short-lived GitHub OIDC JWT — zero static secrets, zero manual setup.
  After auth, the agent reads a config secret. Everything it does is
  captured in Vault's audit log and the token expires automatically.

What to watch in the Vault UI while this runs:
  1. Access → Auth Methods → jwt → Roles → ai-agent-role (bound to this repo)
  2. Identity → Entities → app-08-github-actions-agent  (Agent Registry entry)
  3. Audit log → login event, then a KV read — all attributed to the entity
  4. After the script exits, the token lease disappears automatically
"""

import json
import logging
import os
import sys

import requests

# ── Structured logging — no sensitive data ever logged ───────────────────────

logging.basicConfig(
    level=logging.INFO,
    format='{"ts": "%(asctime)s", "level": "%(levelname)s", "msg": %(message)s}',
    stream=sys.stdout,
)
log = logging.getLogger("agent")

# ── Config from environment — injected by GitHub Actions, never hardcoded ────

VAULT_ADDR      = os.environ["VAULT_ADDR"]
VAULT_NAMESPACE = os.environ.get("VAULT_NAMESPACE", "")
VAULT_ROLE      = os.environ.get("VAULT_ROLE", "ai-agent-role")
VAULT_KV_PATH   = os.environ.get("VAULT_KV_PATH", "app08/kv/data/agents/app-08/config")
# GitHub Actions injects this automatically — contains the OIDC JWT
ACTIONS_ID_TOKEN = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")
ACTIONS_ID_URL   = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL", "")

_session = requests.Session()
_session.verify = True  # TLS verification always on


def _headers(token: str | None = None) -> dict:
    h = {"Content-Type": "application/json"}
    if VAULT_NAMESPACE:
        h["X-Vault-Namespace"] = VAULT_NAMESPACE
    if token:
        h["X-Vault-Token"] = token
    return h


# ── Step 1: Fetch GitHub Actions OIDC JWT ────────────────────────────────────

def get_github_jwt() -> str:
    """Request a GitHub Actions OIDC JWT scoped to our Vault audience."""
    if not ACTIONS_ID_TOKEN or not ACTIONS_ID_URL:
        raise RuntimeError(
            "GitHub Actions OIDC env vars not set. "
            "Ensure 'id-token: write' permission is set in the workflow."
        )
    url = f"{ACTIONS_ID_URL}&audience={VAULT_ADDR}"
    resp = _session.get(url, headers={"Authorization": f"Bearer {ACTIONS_ID_TOKEN}"}, timeout=10)
    resp.raise_for_status()
    jwt = resp.json()["value"]
    log.info('"Fetched GitHub Actions OIDC JWT (no static credentials used)"')
    return jwt


# ── Step 2: Authenticate to Vault ────────────────────────────────────────────

def vault_login(jwt: str) -> str:
    """Exchange the GitHub JWT for a short-lived Vault token."""
    resp = _session.post(
        f"{VAULT_ADDR}/v1/auth/jwt/login",
        json={"role": VAULT_ROLE, "jwt": jwt},
        headers=_headers(),
        timeout=10,
    )
    resp.raise_for_status()
    body = resp.json()
    token = body["auth"]["client_token"]
    ttl   = body["auth"]["lease_duration"]
    policies = body["auth"]["policies"]
    log.info(
        f'"Vault login successful — ttl={ttl}s, policies={policies}, '
        f'entity={body["auth"].get("entity_id", "none")}"'
    )
    return token


# ── Step 3: Read the KV secret ───────────────────────────────────────────────

def read_secret(token: str) -> dict:
    """Read the agent config secret from Vault KV-v2."""
    resp = _session.get(
        f"{VAULT_ADDR}/v1/{VAULT_KV_PATH}",
        headers=_headers(token),
        timeout=10,
    )
    resp.raise_for_status()
    data = resp.json()["data"]["data"]
    log.info(f'"Read KV secret — keys={list(data.keys())}"')
    return data


# ── Step 4: Look up own token (shows in audit log) ───────────────────────────

def lookup_self(token: str) -> dict:
    """Read own token info — demonstrates audit trail in Vault UI."""
    resp = _session.get(
        f"{VAULT_ADDR}/v1/auth/token/lookup-self",
        headers=_headers(token),
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["data"]


# ── Main pipeline ─────────────────────────────────────────────────────────────

def run() -> None:
    print("\n" + "═" * 60)
    print("  App-08: Vault Agentic Auth Demo")
    print("═" * 60)

    print("\n[1/4] Fetching GitHub Actions OIDC JWT...")
    jwt = get_github_jwt()
    print("      ✓ JWT acquired — no static credentials")

    print("\n[2/4] Authenticating to Vault (JWT auth method)...")
    token = vault_login(jwt)
    print("      ✓ Vault token issued — check Agent Registry in Vault UI")

    print("\n[3/4] Reading config secret from Vault KV...")
    secret = read_secret(token)
    print(f"      ✓ Secret read: {json.dumps(secret, indent=8)}")
    print("      ✓ This read is now visible in the Vault audit log")

    print("\n[4/4] Looking up token info...")
    info = lookup_self(token)
    print(f"      ✓ Token TTL: {info.get('ttl')}s — expires automatically, nothing persists")

    print("\n" + "═" * 60)
    print("  Pipeline complete.")
    print("  What to check in Vault UI:")
    print("  → Identity → Entities → app-08-github-actions-agent")
    print("  → Audit log → two events: login + kv read")
    print("  → Leases → token TTL counting down to zero")
    print("═" * 60 + "\n")


if __name__ == "__main__":
    run()
