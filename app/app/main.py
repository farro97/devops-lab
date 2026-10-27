"""
devops-lab sample API.

A deliberately small FastAPI app that gives the infrastructure something
real to run:

  GET  /         app name, version and environment
  GET  /health   liveness check for the load balancer (does NOT touch the DB)
  GET  /db       checks the database connection and returns the Postgres version
  GET  /visits   number of recorded visits
  POST /visits   records a visit and returns the new count

All configuration comes from environment variables, which is how ECS
passes settings and secrets into a container (12-factor style).
"""

import logging
import os

import psycopg
from fastapi import FastAPI, HTTPException
from psycopg.conninfo import make_conninfo

APP_NAME = "devops-lab"
APP_VERSION = os.getenv("APP_VERSION", "local")
ENVIRONMENT = os.getenv("ENVIRONMENT", "local")

# Containers should log to stdout. ECS ships stdout to CloudWatch Logs.
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger(APP_NAME)

app = FastAPI(title=APP_NAME, version=APP_VERSION)


def db_conninfo() -> str | None:
    """Build a Postgres connection string from env vars, or None if unset."""
    host = os.getenv("DB_HOST")
    if not host:
        return None
    return make_conninfo(
        host=host,
        port=os.getenv("DB_PORT", "5432"),
        dbname=os.getenv("DB_NAME", "app"),
        user=os.getenv("DB_USER", "postgres"),
        password=os.getenv("DB_PASSWORD", ""),
        # RDS Postgres 15+ requires TLS by default (rds.force_ssl = 1).
        sslmode=os.getenv("DB_SSLMODE", "require"),
        connect_timeout=5,
    )


def connect() -> psycopg.Connection:
    conninfo = db_conninfo()
    if conninfo is None:
        raise HTTPException(status_code=503, detail="Database is not configured (DB_HOST unset)")
    try:
        return psycopg.connect(conninfo)
    except psycopg.OperationalError as exc:
        log.error("database connection failed: %s", exc)
        raise HTTPException(status_code=503, detail="Database unavailable") from exc


@app.get("/")
def root() -> dict:
    return {"app": APP_NAME, "version": APP_VERSION, "environment": ENVIRONMENT}


@app.get("/health")
def health() -> dict:
    # Keep this check cheap and independent of the database. If the DB has a
    # blip, the load balancer should NOT kill every container. That would turn
    # a small database problem into a full outage.
    return {"status": "ok"}


@app.get("/db")
def db_check() -> dict:
    with connect() as conn:
        version = conn.execute("SELECT version()").fetchone()[0]
    return {"database": "ok", "version": version}


def _ensure_table(conn: psycopg.Connection) -> None:
    conn.execute(
        "CREATE TABLE IF NOT EXISTS visits ("
        " id BIGSERIAL PRIMARY KEY,"
        " visited_at TIMESTAMPTZ NOT NULL DEFAULT now())"
    )


@app.get("/visits")
def get_visits() -> dict:
    with connect() as conn:
        _ensure_table(conn)
        count = conn.execute("SELECT count(*) FROM visits").fetchone()[0]
    return {"visits": count}


@app.post("/visits")
def add_visit() -> dict:
    with connect() as conn:
        _ensure_table(conn)
        conn.execute("INSERT INTO visits DEFAULT VALUES")
        count = conn.execute("SELECT count(*) FROM visits").fetchone()[0]
    log.info("visit recorded, total=%s", count)
    return {"visits": count}
