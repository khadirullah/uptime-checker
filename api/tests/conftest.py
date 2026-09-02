"""In-memory stand-ins for postgres and redis so the api tests need no running services."""

from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.store import DuplicateSite


class FakeStore:
    def __init__(self):
        self.sites = {}
        self.checks = {}
        self.next_id = 1
        self.healthy = True

    def ping(self):
        if not self.healthy:
            raise ConnectionError("postgres down")

    def list_sites(self):
        return [dict(s) for s in self.sites.values()]

    def get_site(self, site_id):
        s = self.sites.get(site_id)
        return dict(s) if s else None

    def create_site(self, name, url):
        if any(s["url"] == url for s in self.sites.values()):
            raise DuplicateSite(url)
        site = {
            "id": self.next_id,
            "name": name,
            "url": url,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        self.sites[self.next_id] = site
        self.next_id += 1
        return dict(site)

    def delete_site(self, site_id):
        return self.sites.pop(site_id, None) is not None

    def list_checks(self, site_id, limit):
        return self.checks.get(site_id, [])[:limit]


class FakeCache:
    def __init__(self):
        self.statuses = {}
        self.queue = []
        self.healthy = True

    def ping(self):
        if not self.healthy:
            raise ConnectionError("redis down")

    def get_statuses(self, site_ids):
        return {i: self.statuses.get(i) for i in site_ids}

    def get_status(self, site_id):
        return self.statuses.get(site_id)

    def enqueue(self, site_id):
        self.queue.append(site_id)

    def delete_status(self, site_id):
        self.statuses.pop(site_id, None)


@pytest.fixture
def store():
    return FakeStore()


@pytest.fixture
def cache():
    return FakeCache()


@pytest.fixture
def client(store, cache):
    app.state.store = store
    app.state.cache = cache
    with TestClient(app) as c:
        yield c
    app.state.store = None
    app.state.cache = None
