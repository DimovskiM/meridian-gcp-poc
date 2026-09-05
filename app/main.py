import logging
import os
from contextlib import asynccontextmanager

from alembic import command
from alembic.config import Config
from fastapi import FastAPI
from sqlalchemy import text

import db

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("meridian")

CANDIDATE_NAME = "Mihajlo Dimovski"
GIT_COMMIT = os.environ.get("GIT_COMMIT", "unknown")
REGION = os.environ.get("REGION", "unknown")

# Arbitrary fixed lock id shared by every instance, so concurrent startups
# serialize their migration attempts instead of racing each other.
MIGRATION_LOCK_ID = 875321


def run_migrations() -> None:
    """Runs Alembic migrations under a Postgres advisory lock.

    Deliberately does not raise: a bad migration must not prevent the app
    from starting and serving traffic. /health's `db` field reflects live
    connectivity independently of whether the schema is fully migrated, so
    the service stays observable instead of going dark.
    """
    try:
        engine = db.get_engine()
        with engine.connect() as conn:
            conn.execute(text("SELECT pg_advisory_lock(:id)"), {"id": MIGRATION_LOCK_ID})
            try:
                alembic_cfg = Config(os.path.join(os.path.dirname(__file__), "alembic.ini"))
                alembic_cfg.set_main_option(
                    "script_location", os.path.join(os.path.dirname(__file__), "alembic")
                )
                alembic_cfg.set_main_option("sqlalchemy.url", db.build_db_url())
                command.upgrade(alembic_cfg, "head")
                logger.info("migrations applied successfully")
            finally:
                conn.execute(text("SELECT pg_advisory_unlock(:id)"), {"id": MIGRATION_LOCK_ID})
    except Exception:
        logger.exception("migration step failed — continuing startup without a fully migrated schema")


@asynccontextmanager
async def lifespan(app: FastAPI):
    run_migrations()
    yield


app = FastAPI(lifespan=lifespan)


@app.get("/health")
def health():
    return {
        "candidate": CANDIDATE_NAME,
        "commit": GIT_COMMIT,
        "region": REGION,
        "db": "ok" if db.check_db_connection() else "error",
        "secret": "ok" if db.check_secret_read() else "error",
    }
