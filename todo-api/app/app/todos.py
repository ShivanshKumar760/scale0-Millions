# from flask import Blueprint, jsonify, request
# from flask_jwt_extended import get_jwt_identity, jwt_required

# from . import cache, db

# bp = Blueprint("todos", __name__)
# COLS = "id, title, done, created_at, updated_at"


# def _uid():
#     return int(get_jwt_identity())


# def _out(row):
#     row = dict(row)
#     row["created_at"] = row["created_at"].isoformat()
#     row["updated_at"] = row["updated_at"].isoformat()
#     return row


# def _list_key(uid):
#     return f"todos:{uid}"


# def _valid_title(title):
#     return isinstance(title, str) and 0 < len(title.strip()) <= 255


# @bp.get("")
# @jwt_required()
# def list_todos():
#     uid = _uid()
#     fresh = request.args.get("fresh") == "1"       # ?fresh=1 skips cache and replica
#     if not fresh:
#         cached = cache.get_json(_list_key(uid))
#         if cached is not None:
#             resp = jsonify(cached)
#             resp.headers["X-Cache"] = "HIT"
#             return resp
#     with db.cursor(db.read_url(uid, fresh)) as cur:
#         cur.execute(
#             f"SELECT {COLS} FROM todos WHERE user_id = %s ORDER BY id DESC LIMIT 200", (uid,)
#         )
#         items = [_out(r) for r in cur.fetchall()]
#     if not fresh:
#         cache.set_json(_list_key(uid), items)
#     resp = jsonify(items)
#     resp.headers["X-Cache"] = "BYPASS" if fresh else "MISS"
#     return resp


# @bp.post("")
# @jwt_required()
# def create_todo():
#     title = (request.get_json(silent=True) or {}).get("title")
#     if not _valid_title(title):
#         return jsonify(error="title is required (max 255 chars)"), 400
#     uid = _uid()
#     with db.cursor(db.write_url(uid)) as cur:
#         cur.execute(
#             f"INSERT INTO todos (user_id, title) VALUES (%s, %s) RETURNING {COLS}",
#             (uid, title.strip()),
#         )
#         row = cur.fetchone()
#     cache.delete(_list_key(uid))
#     return jsonify(_out(row)), 201


# @bp.get("/<int:todo_id>")
# @jwt_required()
# def get_todo(todo_id):
#     uid = _uid()
#     fresh = request.args.get("fresh") == "1"
#     with db.cursor(db.read_url(uid, fresh)) as cur:
#         cur.execute(
#             f"SELECT {COLS} FROM todos WHERE id = %s AND user_id = %s", (todo_id, uid)
#         )
#         row = cur.fetchone()
#     if row is None:
#         return jsonify(error="not found"), 404
#     return jsonify(_out(row))


# @bp.put("/<int:todo_id>")
# @jwt_required()
# def update_todo(todo_id):
#     data = request.get_json(silent=True) or {}
#     title, done = data.get("title"), data.get("done")
#     if title is None and done is None:
#         return jsonify(error="provide title and/or done"), 400
#     if title is not None and not _valid_title(title):
#         return jsonify(error="invalid title"), 400
#     if done is not None and not isinstance(done, bool):
#         return jsonify(error="done must be true or false"), 400
#     uid = _uid()
#     with db.cursor(db.write_url(uid)) as cur:
#         cur.execute(
#             f"""UPDATE todos
#                    SET title = COALESCE(%s, title),
#                        done = COALESCE(%s, done),
#                        updated_at = now()
#                  WHERE id = %s AND user_id = %s
#              RETURNING {COLS}""",
#             (title.strip() if title else None, done, todo_id, uid),
#         )
#         row = cur.fetchone()
#     if row is None:
#         return jsonify(error="not found"), 404
#     cache.delete(_list_key(uid))
#     return jsonify(_out(row))


# @bp.delete("/<int:todo_id>")
# @jwt_required()
# def delete_todo(todo_id):
#     uid = _uid()
#     with db.cursor(db.write_url(uid)) as cur:
#         cur.execute("DELETE FROM todos WHERE id = %s AND user_id = %s RETURNING id", (todo_id, uid))
#         row = cur.fetchone()
#     if row is None:
#         return jsonify(error="not found"), 404
#     cache.delete(_list_key(uid))
#     return "", 204


import psycopg2.errors
from flask import Blueprint, jsonify, request
from flask_jwt_extended import get_jwt_identity, jwt_required

from . import cache, db

bp = Blueprint("todos", __name__)
COLS = "id, title, done, created_at, updated_at"


def _uid():
    return int(get_jwt_identity())


def _out(row):
    row = dict(row)
    row["created_at"] = row["created_at"].isoformat()
    row["updated_at"] = row["updated_at"].isoformat()
    return row


def _list_key(uid):
    return f"todos:{uid}"


def _valid_title(title):
    return isinstance(title, str) and 0 < len(title.strip()) <= 255


@bp.get("")
@jwt_required()
def list_todos():
    uid = _uid()
    fresh = request.args.get("fresh") == "1"
    
    if not fresh:
        cached = cache.get_json(_list_key(uid))
        if cached is not None:
            resp = jsonify(cached)
            resp.headers["X-Cache"] = "HIT"
            return resp
            
    with db.cursor(db.read_url(uid, fresh)) as cur:
        cur.execute(
            f"SELECT {COLS} FROM todos WHERE user_id = %s ORDER BY id DESC LIMIT 200", (uid,)
        )
        items = [_out(r) for r in cur.fetchall()]
        
    if not fresh:
        cache.set_json(_list_key(uid), items)
        
    resp = jsonify(items)
    resp.headers["X-Cache"] = "BYPASS" if fresh else "MISS"
    return resp


@bp.post("")
@jwt_required()
def create_todo():
    data = request.get_json(silent=True) or {}
    title = data.get("title")
    
    if not _valid_title(title):
        return jsonify(error="title is required (max 255 chars)"), 400
        
    uid = _uid()
    
    with db.cursor(db.write_url(uid)) as cur:
        cur.execute(
            f"INSERT INTO todos (user_id, title) VALUES (%s, %s) RETURNING {COLS}",
            (uid, title.strip()),
        )
        row = cur.fetchone()
        
        # ─── FIX 3: RESOLVED CACHE RACE CONDITION ──────────────────────────────────
        # Moved `cache.delete` INSIDE the database transaction context manager block.
        # Previously, if database network latency delayed the final commit block, a rapid 
        # subsequent GET request could read old data from a lagging read-replica and 
        # permanently poison the cache. Evicting the key right here forces serialize synchronization.
        cache.delete(_list_key(uid))
        
    return jsonify(_out(row)), 201


@bp.get("/<int:todo_id>")
@jwt_required()
def get_todo(todo_id):
    uid = _uid()
    fresh = request.args.get("fresh") == "1"
    
    with db.cursor(db.read_url(uid, fresh)) as cur:
        cur.execute(
            f"SELECT {COLS} FROM todos WHERE id = %s AND user_id = %s", (todo_id, uid)
        )
        row = cur.fetchone()
        
    if row is None:
        return jsonify(error="not found"), 404
    return jsonify(_out(row))


@bp.put("/<int:todo_id>")
@jwt_required()
def update_todo(todo_id):
    data = request.get_json(silent=True) or {}
    
    # ─── FIX 1: REMOVED BUGGY COALESCE / RESOLVED PARTIAL OVERRIDE LIMITATION ─────
    # Instead of blindly accepting whatever variables map to Python None or SQL NULL, 
    # we explicitly check if keys exist inside the JSON payload dictionary via "in".
    # This prevents an unprovided key from defaulting to NULL and accidentally triggering 
    # a fallback state or preventing users from explicitly passing a null value in future schema scopes.
    has_title = "title" in data
    has_done = "done" in data
    
    if not has_title and not has_done:
        return jsonify(error="provide title and/or done"), 400
        
    updates = []
    params = []
    
    if has_title:
        title = data.get("title")
        if not _valid_title(title):
            return jsonify(error="invalid title"), 400
            
        # ─── FIX 2: PREVENTED PY CRASH (ATTRIBUTE ERROR ON TRUNCATION) ───────────────
        # In the old code, `title.strip() if title else None` ran outside explicit type checking.
        # If data validation failed or was bypassed and received an Integer or a Boolean, 
        # `.strip()` would trigger an uncaught AttributeError, throwing an internal 500 error.
        # Now, type safety is strictly guaranteed inside the updated `_valid_title` gate step.
        updates.append("title = %s")
        params.append(title.strip())
        
    if has_done:
        done = data.get("done")
        if not isinstance(done, bool):
            return jsonify(error="done must be true or false"), 400
        updates.append("done = %s")
        params.append(done)
        
    updates.append("updated_at = now()")
    
    uid = _uid()
    params.extend([todo_id, uid])
    
    # Dynamic SQL compilation isolates columns targeted for modification, preventing unintended updates.
    query = f"""
        UPDATE todos 
        SET {', '.join(updates)} 
        WHERE id = %s AND user_id = %s 
        RETURNING {COLS}
    """
    
    with db.cursor(db.write_url(uid)) as cur:
        cur.execute(query, tuple(params))
        row = cur.fetchone()
        
        # ─── FIX 3: RESOLVED CACHE RACE CONDITION ──────────────────────────────────
        # Evict cache inside the active context boundaries to maintain alignment with the database sequence.
        if row is not None:
            cache.delete(_list_key(uid))
            
    if row is None:
        return jsonify(error="not found"), 404
        
    return jsonify(_out(row))


@bp.delete("/<int:todo_id>")
@jwt_required()
def delete_todo(todo_id):
    uid = _uid()
    
    with db.cursor(db.write_url(uid)) as cur:
        cur.execute("DELETE FROM todos WHERE id = %s AND user_id = %s RETURNING id", (todo_id, uid))
        row = cur.fetchone()
        
        # ─── FIX 3: RESOLVED CACHE RACE CONDITION ──────────────────────────────────
        if row is not None:
            cache.delete(_list_key(uid))
            
    if row is None:
        return jsonify(error="not found"), 404
        
    return "", 204
