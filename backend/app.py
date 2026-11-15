import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from functools import wraps

import jwt
import click
from flask import Flask, g, jsonify, request
from google.auth.transport.requests import Request as GoogleRequest
from google.oauth2 import id_token

app = Flask(__name__)
DB_PATH = os.getenv("DATABASE_PATH", "/data/practica5.db")
JWT_SECRET = os.getenv("JWT_SECRET", "")
GOOGLE_CLIENT_ID = os.getenv("GOOGLE_CLIENT_ID", "")


def db():
    if "db" not in g:
        os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
        g.db = sqlite3.connect(DB_PATH, timeout=15)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA foreign_keys=ON")
    return g.db


@app.teardown_appcontext
def close_db(_error=None):
    conn = g.pop("db", None)
    if conn is not None:
        conn.close()


def init_db():
    conn = sqlite3.connect(DB_PATH)
    conn.executescript("""
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, name TEXT NOT NULL,
        password_hash TEXT, google_sub TEXT UNIQUE, role TEXT NOT NULL DEFAULT 'user',
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
      );
      CREATE TABLE IF NOT EXISTS books (
        id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        book_key TEXT NOT NULL, data TEXT NOT NULL, updated_at TEXT NOT NULL,
        UNIQUE(user_id, book_key)
      );
      CREATE TABLE IF NOT EXISTS favorites (
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        book_key TEXT NOT NULL, updated_at TEXT NOT NULL,
        PRIMARY KEY(user_id, book_key)
      );
      CREATE TABLE IF NOT EXISTS history (
        id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        query TEXT NOT NULL, searched_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS applied_ops (
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        op_id TEXT NOT NULL, applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
        PRIMARY KEY(user_id, op_id)
      );
    """)
    conn.commit()
    conn.close()


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def token_for(user):
    return jwt.encode({"sub": str(user["id"]), "exp": int(time.time()) + 60 * 60 * 24 * 30}, JWT_SECRET, algorithm="HS256")


def public_user(user):
    return {"id": user["id"], "email": user["email"], "name": user["name"], "role": user["role"]}


def response_user(user):
    return jsonify({"token": token_for(user), "user": public_user(user)})


def require_auth(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        header = request.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return jsonify(error="Autenticación requerida"), 401
        try:
            claims = jwt.decode(header[7:], JWT_SECRET, algorithms=["HS256"])
            g.user = db().execute("SELECT * FROM users WHERE id=?", (int(claims["sub"]),)).fetchone()
        except (jwt.InvalidTokenError, ValueError, KeyError, TypeError):
            return jsonify(error="Sesión inválida o vencida"), 401
        if g.user is None:
            return jsonify(error="Cuenta inexistente"), 401
        return fn(*args, **kwargs)
    return wrapped


def require_admin(fn):
    @wraps(fn)
    @require_auth
    def wrapped(*args, **kwargs):
        if g.user["role"] != "admin":
            return jsonify(error="Permiso de administrador requerido"), 403
        return fn(*args, **kwargs)
    return wrapped


@app.get("/health")
def health():
    try:
        db().execute("SELECT 1")
        return jsonify(status="ok", database="ok", google_configured=bool(GOOGLE_CLIENT_ID))
    except sqlite3.Error:
        return jsonify(status="error", database="error"), 503


@app.post("/auth/register")
def register():
    body = request.get_json(silent=True) or {}
    email = str(body.get("email", "")).strip().lower()
    password = str(body.get("password", ""))
    name = str(body.get("name", email.split("@")[0] if email else "")).strip()
    if "@" not in email or len(password) < 8 or not name:
        return jsonify(error="Ingresa correo válido, nombre y contraseña de 8 caracteres o más"), 400
    salt = secrets.token_bytes(16)
    password_hash = salt.hex() + ":" + hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 310000).hex()
    try:
        conn = db()
        conn.execute("INSERT INTO users(email,name,password_hash) VALUES(?,?,?)", (email, name, password_hash))
        conn.commit()
    except sqlite3.IntegrityError:
        return jsonify(error="El correo ya está registrado"), 409
    return response_user(db().execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()), 201


@app.post("/auth/login")
def login():
    body = request.get_json(silent=True) or {}
    email = str(body.get("email", "")).strip().lower()
    user = db().execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
    stored = user["password_hash"] if user else None
    valid = False
    if stored and ":" in stored:
        salt_hex, digest = stored.split(":", 1)
        candidate = hashlib.pbkdf2_hmac("sha256", str(body.get("password", "")).encode(), bytes.fromhex(salt_hex), 310000).hex()
        valid = hmac.compare_digest(candidate, digest)
    if not valid:
        return jsonify(error="Correo o contraseña incorrectos"), 401
    return response_user(user)


@app.post("/auth/google")
def google_login():
    body = request.get_json(silent=True) or {}
    raw = str(body.get("id_token", ""))
    if not GOOGLE_CLIENT_ID:
        return jsonify(error="Google OAuth no está configurado en el backend"), 503
    try:
        claims = id_token.verify_oauth2_token(raw, GoogleRequest(), GOOGLE_CLIENT_ID)
        if not claims.get("email_verified") or not claims.get("sub") or not claims.get("email"):
            return jsonify(error="Google no verificó el correo"), 401
    except Exception:
        return jsonify(error="Token de Google inválido"), 401
    conn = db()
    user = conn.execute("SELECT * FROM users WHERE google_sub=? OR email=?", (claims["sub"], claims["email"].lower())).fetchone()
    if user:
        conn.execute("UPDATE users SET google_sub=?, name=? WHERE id=?", (claims["sub"], claims.get("name", "Usuario"), user["id"]))
        conn.commit()
        user = conn.execute("SELECT * FROM users WHERE id=?", (user["id"],)).fetchone()
    else:
        conn.execute("INSERT INTO users(email,name,google_sub) VALUES(?,?,?)", (claims["email"].lower(), claims.get("name", "Usuario"), claims["sub"]))
        conn.commit()
        user = conn.execute("SELECT * FROM users WHERE google_sub=?", (claims["sub"],)).fetchone()
    return response_user(user)


@app.get("/auth/me")
@require_auth
def me():
    return jsonify(user=public_user(g.user))


@app.route("/books", methods=["GET", "POST"])
@require_auth
def books():
    conn = db()
    if request.method == "GET":
        rows = conn.execute("SELECT id,book_key,data,updated_at FROM books WHERE user_id=? ORDER BY updated_at DESC", (g.user["id"],)).fetchall()
        return jsonify(items=[{"id": r["id"], "key": r["book_key"], **json.loads(r["data"]), "updated_at": r["updated_at"]} for r in rows])
    body = request.get_json(silent=True) or {}
    key = str(body.get("key", ""))
    if not key or not isinstance(body.get("data"), dict):
        return jsonify(error="Se requiere key y data"), 400
    conn.execute("INSERT INTO books(user_id,book_key,data,updated_at) VALUES(?,?,?,?) ON CONFLICT(user_id,book_key) DO UPDATE SET data=excluded.data,updated_at=excluded.updated_at", (g.user["id"], key, json.dumps(body["data"], ensure_ascii=False), now()))
    conn.commit()
    row = conn.execute("SELECT id,book_key,data,updated_at FROM books WHERE user_id=? AND book_key=?", (g.user["id"], key)).fetchone()
    return jsonify(item={"id": row["id"], "key": row["book_key"], **json.loads(row["data"]), "updated_at": row["updated_at"]}), 201


@app.route("/books/<int:book_id>", methods=["GET", "PUT", "DELETE"])
@require_auth
def book(book_id):
    conn = db()
    row = conn.execute("SELECT * FROM books WHERE id=? AND user_id=?", (book_id, g.user["id"])).fetchone()
    if row is None:
        return jsonify(error="Libro no encontrado"), 404
    if request.method == "GET":
        return jsonify(item={"id": row["id"], "key": row["book_key"], **json.loads(row["data"]), "updated_at": row["updated_at"]})
    if request.method == "DELETE":
        conn.execute("DELETE FROM books WHERE id=? AND user_id=?", (book_id, g.user["id"]))
        conn.execute("DELETE FROM favorites WHERE user_id=? AND book_key=?", (g.user["id"], row["book_key"]))
        conn.commit()
        return "", 204
    body = request.get_json(silent=True) or {}
    if not isinstance(body.get("data"), dict):
        return jsonify(error="Se requiere data"), 400
    conn.execute("UPDATE books SET data=?,updated_at=? WHERE id=? AND user_id=?", (json.dumps(body["data"], ensure_ascii=False), now(), book_id, g.user["id"]))
    conn.commit()
    return jsonify(ok=True)


@app.route("/favorites", methods=["GET", "PUT", "DELETE"])
@require_auth
def favorites():
    conn = db()
    if request.method == "GET":
        rows = conn.execute("SELECT book_key,updated_at FROM favorites WHERE user_id=? ORDER BY updated_at DESC", (g.user["id"],)).fetchall()
        return jsonify(items=[dict(r) for r in rows])
    body = request.get_json(silent=True) or {}
    key = str(body.get("key", ""))
    if not key:
        return jsonify(error="Se requiere key"), 400
    if request.method == "PUT":
        conn.execute("INSERT INTO favorites(user_id,book_key,updated_at) VALUES(?,?,?) ON CONFLICT(user_id,book_key) DO UPDATE SET updated_at=excluded.updated_at", (g.user["id"], key, now()))
    else:
        conn.execute("DELETE FROM favorites WHERE user_id=? AND book_key=?", (g.user["id"], key))
    conn.commit()
    return jsonify(ok=True)


@app.route("/history", methods=["GET", "POST"])
@require_auth
def history():
    conn = db()
    if request.method == "GET":
        rows = conn.execute("SELECT query,searched_at FROM history WHERE user_id=? ORDER BY id DESC LIMIT 100", (g.user["id"],)).fetchall()
        return jsonify(items=[dict(r) for r in rows])
    body = request.get_json(silent=True) or {}
    query = str(body.get("query", "")).strip()
    if not query or len(query) > 200:
        return jsonify(error="Consulta inválida"), 400
    conn.execute("INSERT INTO history(user_id,query,searched_at) VALUES(?,?,?)", (g.user["id"], query, str(body.get("searched_at") or now())))
    conn.commit()
    return jsonify(ok=True), 201


@app.post("/sync")
@require_auth
def sync():
    body = request.get_json(silent=True) or {}
    operations = body.get("operations", [])
    if not isinstance(operations, list) or len(operations) > 200:
        return jsonify(error="Lote de sincronización inválido"), 400
    conn = db()
    with conn:
        for op in operations:
            op_id = str(op.get("id", ""))[:80]
            if not op_id:
                continue
            cur = conn.execute("INSERT OR IGNORE INTO applied_ops(user_id,op_id) VALUES(?,?)", (g.user["id"], op_id))
            if cur.rowcount == 0:
                continue
            kind = op.get("type")
            payload = op.get("payload") or {}
            if kind == "favorite":
                key = str(payload.get("key", ""))
                if key and payload.get("active"):
                    conn.execute("INSERT INTO favorites(user_id,book_key,updated_at) VALUES(?,?,?) ON CONFLICT(user_id,book_key) DO UPDATE SET updated_at=excluded.updated_at", (g.user["id"], key, op.get("created_at") or now()))
                    data = payload.get("book")
                    if isinstance(data, dict):
                        conn.execute("INSERT INTO books(user_id,book_key,data,updated_at) VALUES(?,?,?,?) ON CONFLICT(user_id,book_key) DO UPDATE SET data=excluded.data,updated_at=excluded.updated_at", (g.user["id"], key, json.dumps(data, ensure_ascii=False), op.get("created_at") or now()))
                elif key:
                    conn.execute("DELETE FROM favorites WHERE user_id=? AND book_key=?", (g.user["id"], key))
            elif kind == "history":
                query = str(payload.get("query", "")).strip()
                if query:
                    conn.execute("INSERT INTO history(user_id,query,searched_at) VALUES(?,?,?)", (g.user["id"], query, op.get("created_at") or now()))
    favorites_now = conn.execute("SELECT book_key FROM favorites WHERE user_id=?", (g.user["id"],)).fetchall()
    books_now = conn.execute("SELECT book_key,data,updated_at FROM books WHERE user_id=?", (g.user["id"],)).fetchall()
    history_now = conn.execute("SELECT query,searched_at FROM history WHERE user_id=? ORDER BY id DESC LIMIT 100", (g.user["id"],)).fetchall()
    return jsonify(favorites=[r["book_key"] for r in favorites_now], books=[{"key": r["book_key"], **json.loads(r["data"]), "updated_at": r["updated_at"]} for r in books_now], history=[dict(r) for r in history_now], synced_at=now())


@app.get("/admin/activity")
@require_admin
def admin_activity():
    conn = db()
    users = conn.execute("SELECT id,email,name,role,created_at FROM users ORDER BY email").fetchall()
    out = []
    for user in users:
        histories = conn.execute("SELECT query,searched_at FROM history WHERE user_id=? ORDER BY id DESC LIMIT 50", (user["id"],)).fetchall()
        favorite_rows = conn.execute("SELECT book_key FROM favorites WHERE user_id=? ORDER BY book_key", (user["id"],)).fetchall()
        out.append({**dict(user), "history": [dict(r) for r in histories], "favorites": [r["book_key"] for r in favorite_rows]})
    return jsonify(users=out)


@app.cli.command("make-admin")
@click.argument("email")
def make_admin(email):
    email = email.strip().lower()
    with app.app_context():
        cur = db().execute("UPDATE users SET role='admin' WHERE email=?", (email,))
        db().commit()
        print("Rol admin asignado" if cur.rowcount else "No existe esa cuenta; regístrala primero")


@app.before_request
def startup_check():
    if not os.path.exists(DB_PATH):
        init_db()


if not JWT_SECRET:
    raise RuntimeError("JWT_SECRET es obligatorio; configura un secreto aleatorio fuera del código")
