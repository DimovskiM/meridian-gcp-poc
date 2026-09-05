import logging
import os

from fastapi import FastAPI

import db

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("meridian")

CANDIDATE_NAME = "Mihajlo Dimovski"
GIT_COMMIT = os.environ.get("GIT_COMMIT", "unknown")
REGION = os.environ.get("REGION", "unknown")

# Migrations run as a separate Cloud Run Job (app/migrate.py) before a new
# revision goes live, so cold starts stay fast and a bad migration cannot take
# the service down.
app = FastAPI()


@app.get("/health")
def health():
    return {
        "candidate": CANDIDATE_NAME,
        "commit": GIT_COMMIT,
        "region": REGION,
        "db": "ok" if db.check_db_connection() else "error",
        "secret": "ok" if db.check_secret_read() else "error",
    }
