import os


def database_url() -> str:
    return os.environ.get("DATABASE_URL", "postgresql://uptime:uptime@localhost:5432/uptime")


def redis_url() -> str:
    return os.environ.get("REDIS_URL", "redis://localhost:6379/0")


def check_interval_seconds() -> int:
    # the worker owns this setting. the api only reports it so the board can show it.
    try:
        return max(1, int(os.environ.get("CHECK_INTERVAL_SECONDS", "60")))
    except ValueError:
        return 60
