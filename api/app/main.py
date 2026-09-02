from contextlib import asynccontextmanager
from urllib.parse import urlparse

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field

from . import config
from .cache import RedisCache
from .store import DuplicateSite, PostgresStore


@asynccontextmanager
async def lifespan(app: FastAPI):
    # tests set app.state.store and app.state.cache before the app starts.
    # in that case leave them alone instead of connecting to real services.
    owns = getattr(app.state, "store", None) is None
    if owns:
        app.state.store = PostgresStore(config.database_url())
        app.state.cache = RedisCache(config.redis_url())
    yield
    if owns:
        app.state.store.close()
        app.state.cache.close()


app = FastAPI(title="uptime-checker api", version="0.1.0", lifespan=lifespan)


def get_store(request: Request) -> PostgresStore:
    return request.app.state.store


def get_cache(request: Request) -> RedisCache:
    return request.app.state.cache


class SiteCreate(BaseModel):
    url: str = Field(min_length=1, max_length=2048)
    name: str | None = Field(default=None, max_length=200)


# liveness: the process is up and can answer http. touches nothing else on purpose,
# so a database outage does not make kubernetes restart every api pod.
@app.get("/healthz")
def healthz():
    return {"status": "ok"}


# readiness: can this pod actually serve traffic right now.
@app.get("/readyz")
def readyz(store: PostgresStore = Depends(get_store), cache: RedisCache = Depends(get_cache)):
    problems = {}
    try:
        store.ping()
    except Exception as exc:  # noqa: BLE001
        problems["postgres"] = str(exc)
    try:
        cache.ping()
    except Exception as exc:  # noqa: BLE001
        problems["redis"] = str(exc)
    if problems:
        raise HTTPException(status_code=503, detail=problems)
    return {"status": "ready"}


@app.get("/api/sites")
def list_sites(store: PostgresStore = Depends(get_store), cache: RedisCache = Depends(get_cache)):
    sites = store.list_sites()
    statuses = cache.get_statuses([s["id"] for s in sites])
    for s in sites:
        s["status"] = statuses.get(s["id"])
    return {
        "sites": sites,
        "total": len(sites),
        "check_interval_seconds": config.check_interval_seconds(),
    }


@app.post("/api/sites", status_code=201)
def create_site(
    body: SiteCreate,
    store: PostgresStore = Depends(get_store),
    cache: RedisCache = Depends(get_cache),
):
    url = body.url.strip()
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise HTTPException(status_code=422, detail="url must start with http:// or https://")
    name = (body.name or "").strip() or parsed.netloc
    try:
        site = store.create_site(name, url)
    except DuplicateSite:
        raise HTTPException(status_code=409, detail="site with that url already exists")
    # check it right away instead of waiting for the next scheduler tick
    cache.enqueue(site["id"])
    site["status"] = None
    return site


@app.get("/api/sites/{site_id}")
def get_site(
    site_id: int,
    store: PostgresStore = Depends(get_store),
    cache: RedisCache = Depends(get_cache),
):
    site = store.get_site(site_id)
    if site is None:
        raise HTTPException(status_code=404, detail="site not found")
    site["status"] = cache.get_status(site_id)
    return site


@app.delete("/api/sites/{site_id}", status_code=204)
def delete_site(
    site_id: int,
    store: PostgresStore = Depends(get_store),
    cache: RedisCache = Depends(get_cache),
):
    if not store.delete_site(site_id):
        raise HTTPException(status_code=404, detail="site not found")
    cache.delete_status(site_id)
    return Response(status_code=204)


@app.get("/api/sites/{site_id}/checks")
def list_checks(
    site_id: int,
    limit: int = Query(default=50, ge=1, le=500),
    store: PostgresStore = Depends(get_store),
):
    if store.get_site(site_id) is None:
        raise HTTPException(status_code=404, detail="site not found")
    return {"checks": store.list_checks(site_id, limit)}
