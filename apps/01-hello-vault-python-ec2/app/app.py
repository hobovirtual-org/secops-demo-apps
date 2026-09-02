"""
Hello Vault — Python / Flask
Authenticates to HashiCorp Vault using AWS IAM auth, then reads a KV v2 secret.
"""

import os
import logging
import json

import hvac
import boto3
from flask import Flask, jsonify

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

app = Flask(__name__)

VAULT_ADDR      = os.environ["VAULT_ADDR"]
VAULT_NAMESPACE = os.environ.get("VAULT_NAMESPACE", "")
VAULT_ROLE      = os.environ["VAULT_ROLE"]
SECRET_PATH     = os.environ.get("SECRET_PATH", "config")
MOUNT_POINT     = os.environ.get("MOUNT_POINT", "secret")


def _vault_client() -> hvac.Client:
    """Return an authenticated Vault client using AWS IAM auth."""
    client = hvac.Client(url=VAULT_ADDR, namespace=VAULT_NAMESPACE or None)
    client.auth.aws.iam_login(role=VAULT_ROLE, use_token=True)
    if not client.is_authenticated():
        raise RuntimeError("Vault authentication failed")
    logger.info("Authenticated to Vault via AWS IAM auth")
    return client


@app.route("/")
def index():
    client = _vault_client()
    response = client.secrets.kv.v2.read_secret_version(
        path=SECRET_PATH,
        mount_point=MOUNT_POINT,
        raise_on_deleted_version=True,
    )
    data = response["data"]["data"]
    return jsonify({
        "status": "ok",
        "greeting": data.get("greeting"),
        "db_username": data.get("db_username"),
        # Never return db_password — log scrubbed
    })


@app.route("/health")
def health():
    return jsonify({"status": "healthy"})


if __name__ == "__main__":
    # Bind to localhost only — TLS/proxy terminates outside this process
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", "8080")))
