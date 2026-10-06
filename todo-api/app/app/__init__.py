import socket

from flask import Flask, jsonify
from flask_jwt_extended import JWTManager

from . import db
from .config import Config

jwt = JWTManager()
HOSTNAME = socket.gethostname()


def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)
    jwt.init_app(app)

    from .auth import bp as auth_bp
    from .todos import bp as todos_bp

    app.register_blueprint(auth_bp, url_prefix="/api/auth")
    app.register_blueprint(todos_bp, url_prefix="/api/todos")

    @app.get("/healthz")                 # liveness: "is this process up?" (load balancer uses it)
    def healthz():
        return jsonify(status="ok", host=HOSTNAME)

    @app.get("/readyz")                  # readiness: "can I reach the database?"
    def readyz():
        try:
            url = app.config["SHARD_INDEX_URL"] if db.sharded() else app.config["DATABASE_URL"]
            with db.cursor(url) as cur:
                cur.execute("SELECT 1")
            return jsonify(status="ready")
        except Exception:
            return jsonify(status="database unavailable"), 503

    @app.after_request
    def add_server_header(resp):         # lets you SEE load balancing in curl output
        resp.headers["X-Served-By"] = HOSTNAME
        return resp

    return app