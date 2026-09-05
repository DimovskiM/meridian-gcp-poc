"""Migration entrypoint for the Cloud Run Job (infra/cloudrun.tf).

Runs separately from the API service, so a cold start never pays for a
migration check and a bad migration fails visibly here instead of degrading
the running service. Deliberately raises on failure — the job execution
should go red.
"""

import logging
import os
import sys

from alembic import command
from alembic.config import Config
from sqlalchemy import text

import db

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("meridian")

# Arbitrary fixed lock id, so overlapping job executions serialize instead of
# racing each other.
MIGRATION_LOCK_ID = 875321


def main() -> None:
    here = os.path.dirname(__file__)
    engine = db.get_engine()

    with engine.connect() as conn:
        conn.execute(text("SELECT pg_advisory_lock(:id)"), {"id": MIGRATION_LOCK_ID})
        try:
            cfg = Config(os.path.join(here, "alembic.ini"))
            cfg.set_main_option("script_location", os.path.join(here, "alembic"))
            cfg.set_main_option("sqlalchemy.url", db.build_db_url())
            command.upgrade(cfg, "head")
            logger.info("migrations applied successfully")
        finally:
            conn.execute(text("SELECT pg_advisory_unlock(:id)"), {"id": MIGRATION_LOCK_ID})


if __name__ == "__main__":
    try:
        main()
    except Exception:
        logger.exception("migration failed")
        sys.exit(1)
