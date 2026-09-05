import os
import logging

from sqlalchemy import create_engine, text

logger = logging.getLogger("meridian")

GCP_PROJECT = os.environ.get("GCP_PROJECT")  # unset for local dev
DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "meridian")
DB_USER = os.environ.get("DB_USER", "meridian_app")

# Both secrets are injected by Cloud Run from Secret Manager at instance
# start (see the secret_key_ref blocks in infra/cloudrun.tf). The platform
# fetches them under the service's own identity, so no Secret Manager API
# call is made from application code at all — locally they're just plain env
# vars, so the code path is identical in both environments.
#
# Tradeoff, deliberate and recorded in ASSUMPTIONS.md: /health's `secret`
# field therefore reports whether the mounted secret is present and non-empty,
# not whether Secret Manager is reachable right now. A live API read per
# request would prove more (that the service account still holds
# secretAccessor), but /health is public and unauthenticated, so it would also
# hand anyone an unbounded way to drive Secret Manager API calls and cost. If
# the deeper signal is wanted, the right shape is a cached read with a TTL
# behind an authenticated endpoint, not a live call on every public request.


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
    """Live check: actually executes a query against Cloud SQL this request."""
    try:
        with get_engine().connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception:
        logger.exception("db health check failed")
        return False


def check_secret_read() -> bool:
    """Checks the Secret-Manager-injected token is present this request.

    Not hardcoded: the value comes from Secret Manager via Cloud Run's secret
    injection, so removing the secret, the IAM binding, or the env wiring
    makes this return False.
    """
    token = os.environ.get("THIRD_PARTY_API_TOKEN")
    if token:
        return True
    logger.error("third-party API token missing or empty")
    return False
