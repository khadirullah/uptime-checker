def test_healthz_does_not_depend_on_backends(client, store, cache):
    store.healthy = False
    cache.healthy = False
    assert client.get("/healthz").status_code == 200


def test_readyz_ok(client):
    assert client.get("/readyz").json() == {"status": "ready"}


def test_readyz_reports_which_backend_is_down(client, store):
    store.healthy = False
    r = client.get("/readyz")
    assert r.status_code == 503
    assert "postgres" in r.json()["detail"]
    assert "redis" not in r.json()["detail"]


def test_create_site_defaults_name_to_host_and_enqueues_check(client, cache):
    r = client.post("/api/sites", json={"url": "https://khadirullah.com"})
    assert r.status_code == 201
    body = r.json()
    assert body["name"] == "khadirullah.com"
    assert body["status"] is None
    assert cache.queue == [body["id"]]


def test_create_site_rejects_bad_scheme(client):
    r = client.post("/api/sites", json={"url": "ftp://example.com"})
    assert r.status_code == 422


def test_create_site_rejects_duplicate_url(client):
    client.post("/api/sites", json={"url": "https://example.com"})
    r = client.post("/api/sites", json={"url": "https://example.com"})
    assert r.status_code == 409


def test_list_sites_merges_status_from_cache(client, cache):
    sid = client.post("/api/sites", json={"url": "https://example.com"}).json()["id"]
    cache.statuses[sid] = {"ok": True, "status_code": 200, "latency_ms": 120}
    r = client.get("/api/sites")
    assert r.json()["total"] == 1
    assert r.json()["sites"][0]["status"]["latency_ms"] == 120


def test_list_sites_reports_check_interval(client, monkeypatch):
    monkeypatch.setenv("CHECK_INTERVAL_SECONDS", "30")
    assert client.get("/api/sites").json()["check_interval_seconds"] == 30


def test_get_missing_site_is_404(client):
    assert client.get("/api/sites/999").status_code == 404


def test_delete_site_clears_cached_status(client, cache):
    sid = client.post("/api/sites", json={"url": "https://example.com"}).json()["id"]
    cache.statuses[sid] = {"ok": False}
    assert client.delete(f"/api/sites/{sid}").status_code == 204
    assert sid not in cache.statuses
    assert client.delete(f"/api/sites/{sid}").status_code == 404


def test_list_checks_for_site(client, store):
    sid = client.post("/api/sites", json={"url": "https://example.com"}).json()["id"]
    store.checks[sid] = [{"ok": True, "latency_ms": 90}] * 3
    r = client.get(f"/api/sites/{sid}/checks?limit=2")
    assert len(r.json()["checks"]) == 2


def test_list_checks_missing_site_is_404(client):
    assert client.get("/api/sites/42/checks").status_code == 404
