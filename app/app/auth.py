# import psycopg2.errors
# from flask import Blueprint,current_app,jsonify,request
# from flask_jwt_extended import create_access_token
# from werkzeug.security import check_password_hash,generate_password_hash

# from . import db

# bp = Blueprint("auth",__name__)


# def _credentials():
#     data = request.get_json(silent=True) or {}
#     return (data.get("email") or "").strip().lower(),data.get("password") or ""

# def _register_sharded(email,pw_hash):
#     """Allocate a globally unique user_id from the index DB , then store the user on its shard."""
#     index_url = current_app.config["SHARD_INDEX_URL"]
#     with db.cursor(index_url) as cur:
#         cur.execute("INSERT INTO users_index (email) VALUES (%s) RETURNING user_id",(email,))
#         user_id = cur.fetchone()["user_id"]
#     try:
#         with db.cursor(db.shard_url(user_id)) as cur:
#             cur.execute(
#                 "INSERT INTO users (id,email,password_hash) VALUES (%s,%s,%s)",
#                 (user_id,email,pw_hash),
#             )
#     except Exception:
#         with db.cursor(index_url) as cur:
#             cur.execute("DELETE FROM users_index WHERE user_id = %s", (user_id,))
#         raise
#     return user_id

# @bp.post("/register")
# def register():
#     email , password = _credentials()
#     if "@" not in email or len(email)>255:
#         return jsonify(error="a valid email is required"),400
#     if len(password)<8:
#         return jsonify(error="password must be at least 8 characters"),400
#     pw_hash = generate_password_hash(password)
#     try:
#         if db.sharded():
#             user_id = _register_sharded(email,pw_hash)
#         else:
#             with db.cursor(db.write_url()) as cur:
#                 cur.execute("INSERT INTO users (email, password_hash) VALUES (%s, %s) RETURNING id",(email,pw_hash),)
#                 user_id = cur.fetchone()["id"]
#     except psycopg2.errors.UniqueViolation:
#         return jsonify(error="email already registered"),409
#     return jsonify(id=user_id, email=email), 201


# @bp.post("/login")
# def login():
#     email, password = _credentials()

#     # Login always reads the PRIMARY (never a replica): a user who registers and logs in
#     # one second later must not be rejected because of replication lag.
#     if db.sharded():
#         with db.cursor(current_app.config["SHARD_INDEX_URL"]) as cur:
#             cur.execute("SELECT user_id FROM users_index WHERE email = %s", (email,))
#             row = cur.fetchone()
#         if row is None:
#             return jsonify(error="invalid credentials"), 401
#         user_id = row["user_id"]
#         with db.cursor(db.shard_url(user_id)) as cur:
#             cur.execute("SELECT id, password_hash FROM users WHERE id = %s", (user_id,))
#             user = cur.fetchone()
#     else:
#         with db.cursor(db.write_url()) as cur:
#             cur.execute("SELECT id, password_hash FROM users WHERE email = %s", (email,))
#             user = cur.fetchone()

#     if user is None or not check_password_hash(user["password_hash"], password):
#         return jsonify(error="invalid credentials"), 401

#     token = create_access_token(identity=str(user["id"]))
#     return jsonify(access_token=token)




import psycopg2.errors
from flask import Blueprint, current_app, jsonify, request
from flask_jwt_extended import create_access_token
from werkzeug.security import check_password_hash, generate_password_hash

from . import db

bp = Blueprint("auth", __name__)


def _credentials():
    data = request.get_json(silent=True) or {}
    return (data.get("email") or "").strip().lower(), data.get("password") or ""


def _register_sharded(email, pw_hash):
    """Allocate a globally unique user_id from the index DB, then store the user on its shard.
    
    CRITICAL FIX: Because these are two separate database networks, we cannot use a single transaction. 
    If the shard write fails, we aggressively isolate the cleanup process. If the cleanup fails too, 
    we log a critical alert so the operations team knows a broken row exists in the index map.
    """
    index_url = current_app.config["SHARD_INDEX_URL"]
    
    # Step 1: Claim the unique email globally on the index node
    with db.cursor(index_url) as cur:
        cur.execute("INSERT INTO users_index (email) VALUES (%s) RETURNING user_id", (email,))
        user_id = cur.fetchone()["user_id"]
        
    try:
        # Step 2: Route the heavy profile write to the targeted shard
        with db.cursor(db.shard_url(user_id)) as cur:
            cur.execute(
                "INSERT INTO users (id, email, password_hash) VALUES (%s, %s, %s)",
                (user_id, email, pw_hash),
            )
    except Exception as shard_err:
        # Step 3 Fallback: The shard write crashed. Clean up the index row to free the email address.
        try:
            with db.cursor(index_url) as cur:
                cur.execute("DELETE FROM users_index WHERE user_id = %s", (user_id,))
        except Exception as index_cleanup_err:
            # If the cleanup fails, the data is in a corrupted split-brain state. Log heavily.
            current_app.logger.critical(
                f"CRITICAL: Orphaned user_id {user_id} in index. Shard write failed: {shard_err}. "
                f"Index rollback deletion also failed: {index_cleanup_err}"
            )
        raise shard_err
        
    return user_id


@bp.post("/register")
def register():
    email, password = _credentials()
    if "@" not in email or len(email) > 255:
        return jsonify(error="a valid email is required"), 400
    if len(password) < 8:
        return jsonify(error="password must be at least 8 characters"), 400
        
    pw_hash = generate_password_hash(password)
    
    try:
        if db.sharded():
            user_id = _register_sharded(email, pw_hash)
        else:
            with db.cursor(db.write_url()) as cur:
                cur.execute(
                    "INSERT INTO users (email, password_hash) VALUES (%s, %s) RETURNING id",
                    (email, pw_hash),
                )
                user_id = cur.fetchone()["id"]
                
    except psycopg2.errors.UniqueViolation:
        # Caught if the index database or standard single database flags a duplicate email constraint
        return jsonify(error="email already registered"), 409
    except Exception as e:
        # CRITICAL FIX: Added general catch-all exception tracking. If a database goes offline 
        # or misbehaves during a sharded operation, your old code allowed the server to crash raw. 
        # This logs the traceback safely and gracefully returns a structured HTTP 500 error.
        current_app.logger.error(f"Registration pipeline failed: {str(e)}")
        return jsonify(error="An internal database or system error occurred"), 500
        
    return jsonify(id=user_id, email=email), 201


@bp.post("/login")
def login():
    email, password = _credentials()

    try:
        if db.sharded():
            # Login always reads the PRIMARY (never a replica) to completely bypass replication lag.
            with db.cursor(current_app.config["SHARD_INDEX_URL"]) as cur:
                cur.execute("SELECT user_id FROM users_index WHERE email = %s", (email,))
                row = cur.fetchone()
            if row is None:
                return jsonify(error="invalid credentials"), 401
                
            user_id = row["user_id"]
            with db.cursor(db.shard_url(user_id)) as cur:
                cur.execute("SELECT id, password_hash FROM users WHERE id = %s", (user_id,))
                user = cur.fetchone()
        else:
            with db.cursor(db.write_url()) as cur:
                cur.execute("SELECT id, password_hash FROM users WHERE email = %s", (email,))
                user = cur.fetchone()

        if user is None or not check_password_hash(user["password_hash"], password):
            return jsonify(error="invalid credentials"), 401

        token = create_access_token(identity=str(user["id"]))
        return jsonify(access_token=token)
        
    except Exception as e:
        current_app.logger.error(f"Login pipeline failed: {str(e)}")
        return jsonify(error="An internal login error occurred"), 500
