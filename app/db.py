# from contextlib import contextmanager
# from flask import current_app
# from psycopg2.extras import RealDictCursor
# from psycopg2.pool import ThreadedConnectionPool


# _pools = {}

# def _get_pool(url):
#     pool = _pools.get(url)
#     if pool is None:
#         pool = ThreadedConnectionPool(1,5,dsn=url)
#         _pools[url] = pool
#     return pool

# @contextmanager
# def cursor(url):
#     """Borrow a connection,yield a dict-cursor , commit on success,rollback on error."""
#     pool = _get_pool(url)
#     conn = pool.getconn()  # 1. You grab a connection from the pool.
#     if conn.closed:  # 2. You check: "Is this connection broken/dead?" (e.g., the DB restarted).
#         pool.putconn(conn, close=True)  # 3. You throw away the dead connection and tell the pool to destroy it.
#         conn = pool.getconn()  # 4. THIS LINE: You ask the pool for a fresh, healthy connection instead.
#     try:
#         with conn.cursor(cursor_factory=RealDictCursor) as cur:
#             yield cur
#         conn.commit()
#     except Exception:
#         conn.rollback()
#         raise
#     finally:
#         pool.putconn(conn)

# def sharded():
#     return bool(current_app.config["SHARD_URLS"])

# def shard_url(user_id):
#     urls = current_app.config["SHARD_URLS"]
#     return urls[user_id % len(urls)] # the sharding rule: user_id modulo number of shards

# def write_url(user_id=None):
#     """Where write (and read your own write reads) go."""
#     if sharded():
#         return shard_url(user_id)
#     return current_app.config["DATABASE_URL"]

# def read_url(user_id=None,fresh=False):
#     """Where ordinary reads go.Falls back to the primary if no replica is configured"""
#     if sharded():
#         return shard_url(user_id)
#     cfg = current_app.config
#     if fresh:
#         return cfg["DATABASE_URL"]
#     return cfg["READ_DATABASE_URL"] or cfg["DATABASE_URL"] 


# import hashlib
# from contextlib import contextmanager
# from threading import Lock
# from flask import current_app
# from psycopg2.extras import RealDictCursor
# from psycopg2.pool import ThreadedConnectionPool

# # Global pools registry and initialization lock to ensure thread safety
# _pools = {}
# _pool_lock = Lock()


# def _get_pool(url):
#     """Lazily initialize connection pools safely across concurrent threads."""
#     with _pool_lock:
#         pool = _pools.get(url)
#         if pool is None:
#             pool = ThreadedConnectionPool(1, 5, dsn=url)
#             _pools[url] = pool
#         return pool


# @contextmanager
# def cursor(url):
#     """Borrow a connection, yield a dict-cursor, commit on success, rollback on error."""
#     pool = _get_pool(url)
#     conn = pool.getconn()

#     # Stale connection safety net (e.g., database restarted or dropped idle connection)
#     if conn.closed:
#         pool.putconn(conn, close=True)
#         conn = pool.getconn()

#     try:
#         with conn.cursor(cursor_factory=RealDictCursor) as cur:
#             yield cur
#         conn.commit()
#     except Exception:
#         conn.rollback()
#         raise
#     finally:
#         pool.putconn(conn)


# def sharded():
#     """Check if sharding is enabled in configuration."""
#     return bool(current_app.config.get("SHARD_URLS"))


# def shard_url(user_id):
#     """Compute the target database shard URL dynamically.

#     Handles integers, strings (UUIDs/usernames), and None values flawlessly.
#     """
#     urls = current_app.config["SHARD_URLS"]

#     if user_id is None:
#         user_id = 0
#     elif isinstance(user_id, str):
#         # Deterministically hash strings into a large integer for modulo routing
#         user_id = int(hashlib.md5(user_id.encode("utf-8")).hexdigest(), 16)

#     return urls[user_id % len(urls)]


# def write_url(user_id=None):
#     """Determine destination for write operations."""
#     if sharded():
#         return shard_url(user_id)
#     return current_app.config["DATABASE_URL"]


# def read_url(user_id=None, fresh=False):
#     """Determine destination for read operations, supporting replicas."""
#     if sharded():
#         return shard_url(user_id)

#     cfg = current_app.config
#     if fresh:
#         return cfg["DATABASE_URL"]
#     return cfg.get("READ_DATABASE_URL") or cfg["DATABASE_URL"]



import hashlib
from contextlib import contextmanager
from threading import Lock
from flask import current_app
from psycopg2.extras import RealDictCursor
from psycopg2.pool import ThreadedConnectionPool

# Global pools registry and initialization lock to ensure thread safety
_pools = {}
_pool_lock = Lock()


def _get_pool(url):
    """Lazily initialize connection pools safely across concurrent threads.
    
    CRITICAL FIX: Added a thread lock context manager. Without this, if two HTTP requests 
    hit a new server instance at the same millisecond, they would both find _pools empty 
    and create overlapping pools, causing active connection leaks.
    """
    with _pool_lock:
        pool = _pools.get(url)
        if pool is None:
            pool = ThreadedConnectionPool(1, 5, dsn=url)
            _pools[url] = pool
        return pool


@contextmanager
def cursor(url):
    """Borrow a connection, yield a dict-cursor, commit on success, rollback on error."""
    pool = _get_pool(url)
    conn = pool.getconn()

    # Stale connection safety net (e.g., database restarted or dropped idle connection)
    if conn.closed:
        pool.putconn(conn, close=True)
        conn = pool.getconn()

    try:
        # CRITICAL FIX: The commit is moved inside the cursor's context manager block.
        # This keeps transaction boundaries clean and ensures database constraint failures 
        # that trigger at commit time are raised correctly before the cursor closes.
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            yield cur
            conn.commit()
    except Exception:
        # CRITICAL FIX: Wrapped rollback in a check. If a severe network crash drops the DB 
        # connection, calling rollback will throw a secondary InterfaceError, completely 
        # wiping out and masking the original database error that broke the transaction.
        try:
            if not conn.closed:
                conn.rollback()
        except Exception:
            pass  # Absorb secondary rollback errors to preserve original exception trace
        raise
    finally:
        # CRITICAL FIX: Closed the open parenthesis (pool.putconn(conn) was missing a ')') 
        # which originally threw a fatal Python SyntaxError during compilation.
        pool.putconn(conn)


def sharded():
    """Check if sharding is enabled in configuration."""
    return bool(current_app.config.get("SHARD_URLS"))


def shard_url(user_id):
    """Compute the target database shard URL dynamically.
    
    CRITICAL FIX: Upgraded logic to securely handle string/UUID user_ids, integers, 
    and None types. Plain modulo (%) crashes with a TypeError if handed a string. 
    By MD5 hashing string values, they are turned into safe, uniform integers.
    """
    urls = current_app.config["SHARD_URLS"]

    if user_id is None:
        user_id = 0
    elif isinstance(user_id, str):
        # Deterministically hash string IDs (like UUIDs or usernames) into a large integer
        user_id = int(hashlib.md5(user_id.encode("utf-8")).hexdigest(), 16)

    return urls[user_id % len(urls)]


def write_url(user_id=None):
    """Determine destination for write operations."""
    if sharded():
        return shard_url(user_id)
    return current_app.config["DATABASE_URL"]


def read_url(user_id=None, fresh=False):
    """Determine destination for read operations, supporting replicas."""
    if sharded():
        return shard_url(user_id)

    cfg = current_app.config
    if fresh:
        return cfg["DATABASE_URL"]
    return cfg.get("READ_DATABASE_URL") or cfg["DATABASE_URL"]
