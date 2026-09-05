import os
import logging

from sqlalchemy import create_engine, text
from google.cloud import secretmanager

logger = logging.getLogger("meridian")

GCP_PROJECT = os.environ.get("GCP_PROJECT")  # unset for local dev
DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "meridian")
DB_USER = os.environ.get("DB_USER", "meridian_app")

DB_PASSWORD_SECRET_NAME = os.environ.get("DB_PASSWORD_SECRET_NAME", "db-password")
THIRD_PARTY_TOKEN_SECRET_NAME = os.environ.get(
    "THIRD_PARTY_TOKEN_SECRET_NAME", "third-party-api-token"
)

_secret_client = None


def _client():
    global _secret_client
    if _secret_client is None:
        _secret_client = secretmanager.SecretManagerServiceClient()
    return _secret_client


def read_secret(secret_name: str) -> str:
    """Reads the latest version of a secret. Live call every time — no caching.

    Deployed (GCP_PROJECT set): reads from Secret Manager under the app's own
    service account identity. Local dev (GCP_PROJECT unset): reads a same-named
    env var instead, so local development never needs real Secret Manager access.
    """
    if not GCP_PROJECT:
        return os.environ[secret_name.upper().replace("-", "_")]

    name = f"projects/{GCP_PROJECT}/secrets/{secret_name}/versions/latest"
    response = _client().access_secret_version(name=name)
    return response.payload.data.decode("utf-8")


def build_db_url() -> str:
    password = read_secret(DB_PASSWORD_SECRET_NAME)
    return f"postgresql+psycopg://{DB_USER}:{password}@{DB_HOST}:{DB_PORT}/{DB_NAME}"


_engine = None


def get_engine():
    global _engine
    if _engine is None:
        _engine = create_engine(build_db_url(), pool_pre_ping=True, pool_size=2, max_overflow=2)
    return _engine


def check_db_connection() -> bool:
    """Live check: actually executes a query against Cloud SQL this request."""
    try:
        with get_engine().connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception:
        logger.exception("db health check failed")
        return False


def check_secret_read() -> bool:
    """Live check: actually reads a secret from Secret Manager this request."""
    try:
        read_secret(THIRD_PARTY_TOKEN_SECRET_NAME)
        return True
    except Exception:
        logger.exception("secret health check failed")
        return False
