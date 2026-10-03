import json

import redis
from flask import current_app

_client = None


def _redis():
    global _client
    url = current_app.config.get("REDIS_URL")
    if not url:
        return None
    if _client is None:
        _client = redis.Redis.from_url(url, decode_responses=True, socket_timeout=1)
    return _client


def get_json(key):
    r = _redis()
    if r is None:
        return None
    try:
        raw = r.get(key)
        return json.loads(raw) if raw is not None else None
    except redis.RedisError:
        return None                      # cache down? just fall through to the database


def set_json(key, value):
    r = _redis()
    if r is None:
        return
    try:
        r.setex(key, current_app.config["CACHE_TTL_SECONDS"], json.dumps(value))
    except redis.RedisError:
        pass


def delete(key):
    r = _redis()
    if r is None:
        return
    try:
        r.delete(key)
    except redis.RedisError:
        pass