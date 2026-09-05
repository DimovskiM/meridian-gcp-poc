import logging
import os

from fastapi import FastAPI

import db

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("meridian")

CANDIDATE_NAME = "Mihajlo Dimovski"
GIT_COMMIT = os.environ.get("GIT_COMMIT", "unknown")
REGION = os.environ.get("REGION", "unknown")

# No migrations here — they run as a separate Cloud Run Job (app/migrate.py,
# infra/cloudrun.tf) before a new revision goes live. Keeping them out of
# startup means cold starts stay fast and a failed migration can never take
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
