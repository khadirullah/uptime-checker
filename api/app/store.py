"""Postgres access. Everything the api reads or writes in the database goes through here."""

from datetime import datetime
from typing import Any

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool


class DuplicateSite(Exception):
    pass


class PostgresStore:
    def __init__(self, dsn: str):
        self.pool = ConnectionPool(dsn, min_size=1, max_size=5, kwargs={"row_factory": dict_row})

    def close(self) -> None:
        self.pool.close()

    def ping(self) -> None:
        with self.pool.connection() as conn:
            conn.execute("SELECT 1")

    def list_sites(self) -> list[dict[str, Any]]:
        with self.pool.connection() as conn:
            rows = conn.execute(
                "SELECT id, name, url, created_at FROM sites ORDER BY id"
            ).fetchall()
        return [_site(r) for r in rows]

    def get_site(self, site_id: int) -> dict[str, Any] | None:
        with self.pool.connection() as conn:
            row = conn.execute(
                "SELECT id, name, url, created_at FROM sites WHERE id = %s", (site_id,)
            ).fetchone()
        return _site(row) if row else None

    def create_site(self, name: str, url: str) -> dict[str, Any]:
        try:
            with self.pool.connection() as conn:
                row = conn.execute(
                    "INSERT INTO sites (name, url) VALUES (%s, %s) "
                    "RETURNING id, name, url, created_at",
                    (name, url),
                ).fetchone()
        except psycopg.errors.UniqueViolation as exc:
            raise DuplicateSite(url) from exc
        return _site(row)

    def delete_site(self, site_id: int) -> bool:
        with self.pool.connection() as conn:
            cur = conn.execute("DELETE FROM sites WHERE id = %s", (site_id,))
        return cur.rowcount > 0

    def list_checks(self, site_id: int, limit: int) -> list[dict[str, Any]]:
        with self.pool.connection() as conn:
            rows = conn.execute(
                "SELECT checked_at, ok, status_code, latency_ms, error "
                "FROM checks WHERE site_id = %s ORDER BY checked_at DESC LIMIT %s",
                (site_id, limit),
            ).fetchall()
        return [_check(r) for r in rows]


def _site(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "name": row["name"],
        "url": row["url"],
        "created_at": _iso(row["created_at"]),
    }


def _check(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "checked_at": _iso(row["checked_at"]),
        "ok": row["ok"],
        "status_code": row["status_code"],
        "latency_ms": row["latency_ms"],
        "error": row["error"],
    }


def _iso(value: datetime) -> str:
    return value.isoformat()
