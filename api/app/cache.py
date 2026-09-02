"""Redis access. The worker writes the latest result per site here and the api reads it.

Keys:
  checks:queue          list of site ids waiting to be checked (worker pops from the right)
  site:<id>:status      JSON of the most recent check for that site
"""

import json
from typing import Any

import redis

QUEUE_KEY = "checks:queue"


def status_key(site_id: int) -> str:
    return f"site:{site_id}:status"


class RedisCache:
    def __init__(self, url: str):
        self.client = redis.Redis.from_url(url, decode_responses=True)

    def close(self) -> None:
        self.client.close()

    def ping(self) -> None:
        self.client.ping()

    def get_statuses(self, site_ids: list[int]) -> dict[int, dict[str, Any] | None]:
        if not site_ids:
            return {}
        raw = self.client.mget([status_key(i) for i in site_ids])
        return {i: (json.loads(v) if v else None) for i, v in zip(site_ids, raw)}

    def get_status(self, site_id: int) -> dict[str, Any] | None:
        raw = self.client.get(status_key(site_id))
        return json.loads(raw) if raw else None

    def enqueue(self, site_id: int) -> None:
        self.client.lpush(QUEUE_KEY, site_id)

    def delete_status(self, site_id: int) -> None:
        self.client.delete(status_key(site_id))
