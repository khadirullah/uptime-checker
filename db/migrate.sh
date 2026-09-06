#!/bin/sh
# applies every /migrations/*.sql in name order. stops on the first error.
# each file is idempotent (IF NOT EXISTS), so running this again is harmless.
set -e
: "${POSTGRES_HOST:=postgres}"
: "${POSTGRES_USER:=uptime}"
: "${POSTGRES_DB:=uptime}"

until pg_isready -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -q; do
  echo "waiting for postgres at $POSTGRES_HOST"
  sleep 2
done

for f in /migrations/*.sql; do
  echo "applying $f"
  psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f "$f"
done
echo "migrations done"
