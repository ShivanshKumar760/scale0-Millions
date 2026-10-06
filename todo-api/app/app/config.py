import os
from datetime import timedelta


class Config:
    JWT_SECRET_KEY = os.environ["JWT_SECRET_KEY"]          # must be identical on every app server
    JWT_ACCESS_TOKEN_EXPIRES = timedelta(
        seconds=int(os.getenv("JWT_EXPIRES_SECONDS", "3600"))
    )

    DATABASE_URL = os.getenv("DATABASE_URL")                # the primary (reads + writes)
    # READ_DATABASE_URL = os.getenv("READ_DATABASE_URL")      # Stage 4: a read replica
    READ_DATABASE_URLS = [u.strip() for u in os.getenv("READ_DATABASE_URL", "").split(",") if u.strip()]

    # Stage 5: comma-separated list; position in the list = shard number
    SHARD_URLS = [u.strip() for u in os.getenv("SHARD_URLS", "").split(",") if u.strip()]
    SHARD_INDEX_URL = os.getenv("SHARD_INDEX_URL")

    REDIS_URL = os.getenv("REDIS_URL")                      # Stage 4: cache
    CACHE_TTL_SECONDS = int(os.getenv("CACHE_TTL_SECONDS", "30"))