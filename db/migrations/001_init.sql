CREATE TABLE IF NOT EXISTS sites (
    id          SERIAL PRIMARY KEY,
    name        TEXT        NOT NULL,
    url         TEXT        NOT NULL UNIQUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS checks (
    id          BIGSERIAL PRIMARY KEY,
    site_id     INTEGER     NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    checked_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ok          BOOLEAN     NOT NULL,
    status_code INTEGER,
    latency_ms  INTEGER     NOT NULL,
    error       TEXT
);

CREATE INDEX IF NOT EXISTS checks_site_checked_idx
    ON checks (site_id, checked_at DESC);
