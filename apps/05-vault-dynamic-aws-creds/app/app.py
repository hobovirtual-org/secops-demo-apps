"""
Vault Dynamic AWS Credentials — Python / Flask
Demonstrates using Vault's AWS secrets engine to obtain short-lived IAM
credentials, then uses those credentials to call a real AWS API (S3 list).
"""

import os
import logging

import hvac
import boto3
from flask import Flask, jsonify

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

app = Flask(__name__)

VAULT_ADDR       = os.environ["VAULT_ADDR"]
VAULT_NAMESPACE  = os.environ.get("VAULT_NAMESPACE", "")
VAULT_ROLE       = os.environ["VAULT_ROLE"]
AWS_ROLE_PATH    = os.environ["AWS_ROLE_PATH"]
VAULT_AWS_BACKEND = os.environ.get("VAULT_AWS_BACKEND", "aws/dynamic/vault-dynamic-aws")


def _vault_client() -> hvac.Client:
    client = hvac.Client(url=VAULT_ADDR, namespace=VAULT_NAMESPACE or None)
    client.auth.aws.iam_login(role=VAULT_ROLE, use_token=True)
    if not client.is_authenticated():
        raise RuntimeError("Vault authentication failed")
    return client


def _get_dynamic_aws_creds(client: hvac.Client) -> dict:
    """Request short-lived IAM credentials from Vault's AWS secrets engine."""
    response = client.secrets.aws.generate_credentials(
        name=AWS_ROLE_PATH,
        mount_point=VAULT_AWS_BACKEND,
    )
    return response["data"]


@app.route("/")
def index():
    vault_client = _vault_client()
    creds = _get_dynamic_aws_creds(vault_client)

    # Use the dynamic credentials to list S3 buckets
    s3 = boto3.client(
        "s3",
        aws_access_key_id=creds["access_key"],
        aws_secret_access_key=creds["secret_key"],
        aws_session_token=creds.get("security_token"),
    )
    buckets = [b["Name"] for b in s3.list_buckets().get("Buckets", [])]

    return jsonify({
        "status":      "ok",
        "description": "Dynamic IAM credentials from Vault — short-lived, auto-revoked",
        "iam_user":    creds.get("username", "sts-session"),
        "s3_buckets":  buckets,
        # Never log or return the actual access_key/secret_key
    })


@app.route("/health")
def health():
    return jsonify({"status": "healthy"})


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", "8080")))
