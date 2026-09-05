import os
import logging

from sqlalchemy import create_engine, text

logger = logging.getLogger("meridian")

DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "meridian")
DB_USER = os.environ.get("DB_USER", "meridian_app")

# Both secrets arrive as plain env vars: Cloud Run injects them from Secret
# Manager at instance start (secret_key_ref in infra/cloudrun.tf), so this code
# never calls the Secret Manager API and the local path is identical.


def build_db_url() -> str:
    password = os.environ["DB_PASSWORD"]
    return f"postgresql+psycopg://{DB_USER}:{password}@{DB_HOST}:{DB_PORT}/{DB_NAME}"


_engine = None


def get_engine():
    global _engine
    if _engine is None:
        _engine = create_engine(build_db_url(), pool_pre_ping=True, pool_size=2, max_overflow=2)
    return _engine


def check_db_connection() -> bool:
    """Runs a real query against Cloud SQL on this request."""
    try:
        with get_engine().connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception:
        logger.exception("db health check failed")
        return False


def check_secret_read() -> bool:
    """Checks the injected secret is present on this request.

    Not hardcoded: removing the secret, the IAM binding, or the env wiring
    makes this return False. See ASSUMPTIONS.md for why this is a presence
    check rather than a live Secret Manager read.
    """
    token = os.environ.get("THIRD_PARTY_API_TOKEN")
    if token:
        return True
    logger.error("third-party API token missing or empty")
    return False
