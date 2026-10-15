"""Query service for the photogrammetry pipeline.

Read-only REST API over the `images` table. Serves two public routes (mounted
behind CloudFront and an ALB):

    GET /images   filtered listing of image metadata
    GET /image    resolves a stored s3url to a short-lived pre-signed GET URL

Datetime columns are stored as naive UTC by the capture Lambda, so values are
parsed and rendered with an explicit `Z` suffix.
"""

import logging
import os
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import urlparse

import boto3
import pymysql
from flask import Flask, jsonify, redirect, request

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("query")

app = Flask(__name__)

# --- Configuration ---------------------------------------------------------

DB_HOST = os.environ.get("DB_HOST")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))
DB_NAME = os.environ.get("DB_NAME", "image-metadata")
DB_USER = os.environ.get("DB_USER")
DB_PASSWORD = os.environ.get("DB_PASSWORD")
DB_CONNECT_TIMEOUT = int(os.environ.get("DB_CONNECT_TIMEOUT", "5"))

IMAGE_BUCKET = os.environ.get("IMAGE_BUCKET", "image-bucket")
PRESIGN_EXPIRES_IN = int(os.environ.get("PRESIGN_EXPIRES_IN", "900"))
REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "*")

DEFAULT_LIMIT = int(os.environ.get("DEFAULT_LIMIT", "100"))
MAX_LIMIT = int(os.environ.get("MAX_LIMIT", "500"))

COLUMNS = [
    "s3url",
    "location",
    "latitude",
    "longitude",
    "altitude",
    "horizontalAccuracy",
    "imageDt",
    "description",
    "heading",
    "pitch",
    "roll",
    "createDt",
]

DATETIME_COLUMNS = {"imageDt", "createDt"}
NUMERIC_COLUMNS = {
    "latitude",
    "longitude",
    "altitude",
    "horizontalAccuracy",
    "heading",
    "pitch",
    "roll",
}

# filter param -> column. Only these names are ever interpolated into SQL.
RANGE_FILTERS = {
    "latitude": "latitude",
    "longitude": "longitude",
    "altitude": "altitude",
    "heading": "heading",
    "pitch": "pitch",
    "roll": "roll",
    "horizontalAccuracy": "horizontalAccuracy",
}
DATETIME_FILTERS = {
    "createDt": "createDt",
    "imageDt": "imageDt",
}
TEXT_FILTERS = {
    "location": "location",
    "description": "description",
}
# orderBy param values are restricted to real column names.
ORDER_COLUMNS = {column: column for column in COLUMNS}


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# --- Helpers ---------------------------------------------------------------


def _db_credentials():
    """Return the DB connection settings from the environment."""
    return {
        "host": DB_HOST,
        "port": DB_PORT,
        "user": DB_USER,
        "password": DB_PASSWORD,
        "database": DB_NAME,
    }


def _connect():
    """Open a new connection. Called per request, never at import time."""
    creds = _db_credentials()
    return pymysql.connect(
        host=creds["host"],
        port=creds["port"],
        user=creds["user"],
        password=creds["password"],
        database=creds["database"],
        connect_timeout=DB_CONNECT_TIMEOUT,
        cursorclass=pymysql.cursors.DictCursor,
    )


def _parse_datetime(value, field):
    """Parse an ISO-8601 instant and return a naive UTC datetime for MySQL."""
    raw = value.strip()
    if raw.endswith(("Z", "z")):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        msg = f"'{field}' is not a valid ISO-8601 datetime"
        raise ApiError(400, msg) from None
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone(timezone.utc).replace(tzinfo=None)
    return parsed


def _parse_number(value, field):
    try:
        return float(value)
    except (TypeError, ValueError):
        raise ApiError(400, f"'{field}' must be a number") from None


def _parse_int(value, field):
    try:
        return int(value)
    except (TypeError, ValueError):
        raise ApiError(400, f"'{field}' must be an integer") from None


def _serialize(row):
    out = {}
    for key, value in row.items():
        if value is None:
            out[key] = None
        elif isinstance(value, Decimal):
            out[key] = float(value)
        elif isinstance(value, datetime):
            # Stored values are naive UTC; stamp the zone explicitly.
            out[key] = value.replace(microsecond=0).isoformat() + "Z"
        else:
            out[key] = value
    return out


def _build_filters(args):
    """Translate query params into (where_clauses, params)."""
    clauses = []
    params = []

    for name, column in DATETIME_FILTERS.items():
        since = args.get(f"{name}Since")
        before = args.get(f"{name}Before")
        if since:
            clauses.append(f"`{column}` >= %s")
            params.append(_parse_datetime(since, f"{name}Since"))
        if before:
            clauses.append(f"`{column}` <= %s")
            params.append(_parse_datetime(before, f"{name}Before"))

    for name, column in RANGE_FILTERS.items():
        minimum = args.get(f"{name}Min")
        maximum = args.get(f"{name}Max")
        if minimum:
            clauses.append(f"`{column}` >= %s")
            params.append(_parse_number(minimum, f"{name}Min"))
        if maximum:
            clauses.append(f"`{column}` <= %s")
            params.append(_parse_number(maximum, f"{name}Max"))

    for name, column in TEXT_FILTERS.items():
        value = args.get(name)
        if value:
            clauses.append(f"`{column}` LIKE %s")
            params.append(f"%{value.strip()}%")

    s3url = args.get("s3url")
    if s3url:
        clauses.append("`s3url` = %s")
        params.append(s3url.strip())

    bbox = args.get("bbox")
    if bbox:
        parts = [part.strip() for part in bbox.split(",")]
        if len(parts) != 4:
            raise ApiError(400, "'bbox' must be minLon,minLat,maxLon,maxLat")
        min_lon, min_lat, max_lon, max_lat = parts
        clauses.append("`longitude` >= %s")
        params.append(_parse_number(min_lon, "bbox"))
        clauses.append("`latitude` >= %s")
        params.append(_parse_number(min_lat, "bbox"))
        clauses.append("`longitude` <= %s")
        params.append(_parse_number(max_lon, "bbox"))
        clauses.append("`latitude` <= %s")
        params.append(_parse_number(max_lat, "bbox"))

    return clauses, params


def _order_clause(args):
    order_by = args.get("orderBy", "createDt")
    if order_by not in ORDER_COLUMNS:
        names = sorted(ORDER_COLUMNS)
        raise ApiError(400, f"'orderBy' must be one of {names}")
    direction = args.get("order", "desc").lower()
    if direction not in ("asc", "desc"):
        raise ApiError(400, "'order' must be 'asc' or 'desc'")
    direction_sql = "ASC" if direction == "asc" else "DESC"
    return f"`{ORDER_COLUMNS[order_by]}` {direction_sql}"


def _s3_key_from_url(url):
    """Validate a stored s3url and return its object key."""
    parsed = urlparse(url.strip())

    if parsed.scheme == "s3":
        if parsed.netloc != IMAGE_BUCKET:
            raise ApiError(400, "url does not belong to the image bucket")
        key = parsed.path.lstrip("/")
    elif parsed.scheme == "https":
        expected = (
            f"{IMAGE_BUCKET}.s3.{REGION}.amazonaws.com" if REGION else None,
            f"{IMAGE_BUCKET}.s3.amazonaws.com",
        )
        if parsed.netloc not in expected:
            raise ApiError(400, "url does not belong to the image bucket")
        key = parsed.path.lstrip("/")
    else:
        raise ApiError(400, "url must be an https or s3 URL")

    if not key:
        raise ApiError(400, "url is missing an object key")
    return key


# --- Routes ----------------------------------------------------------------


@app.after_request
def _add_cors(response):
    response.headers["Access-Control-Allow-Origin"] = ALLOWED_ORIGIN
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    response.headers["Access-Control-Allow-Methods"] = "GET,OPTIONS"
    return response


@app.errorhandler(ApiError)
def _handle_api_error(error):
    return jsonify({"error": error.message}), error.status


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


@app.get("/images")
def list_images():
    clauses, params = _build_filters(request.args)
    order_sql = _order_clause(request.args)

    limit = _parse_int(request.args.get("limit", DEFAULT_LIMIT), "limit")
    offset = _parse_int(request.args.get("offset", 0), "offset")
    if limit < 1 or limit > MAX_LIMIT:
        raise ApiError(400, f"'limit' must be between 1 and {MAX_LIMIT}")
    if offset < 0:
        raise ApiError(400, "'offset' must not be negative")

    where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
    sql = (
        f"SELECT {', '.join('`' + c + '`' for c in COLUMNS)} FROM images"
        f"{where} ORDER BY {order_sql} LIMIT %s OFFSET %s"
    )

    try:
        connection = _connect()
    except pymysql.MySQLError:
        logger.exception("Database connection failed")
        raise ApiError(503, "Database unavailable") from None

    try:
        with connection.cursor() as cursor:
            cursor.execute(sql, params + [limit, offset])
            rows = cursor.fetchall()
    except pymysql.MySQLError:
        logger.exception("Query failed")
        raise ApiError(500, "Query failed") from None
    finally:
        connection.close()

    images = [_serialize(row) for row in rows]
    payload = {
        "count": len(images),
        "limit": limit,
        "offset": offset,
        "images": images,
    }
    return jsonify(payload)


@app.get("/image")
def show_image():
    url = request.args.get("url")
    if not url:
        raise ApiError(400, "'url' is required")

    key = _s3_key_from_url(url)

    try:
        connection = _connect()
    except pymysql.MySQLError:
        logger.exception("Database connection failed")
        raise ApiError(503, "Database unavailable") from None

    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT `s3url` FROM images WHERE `s3url` = %s", (url.strip(),)
            )
            exists = cursor.fetchone()
    except pymysql.MySQLError:
        logger.exception("Lookup failed")
        raise ApiError(500, "Lookup failed") from None
    finally:
        connection.close()

    if not exists:
        raise ApiError(404, "Unknown image")

    client = boto3.client("s3", region_name=REGION)
    presigned = client.generate_presigned_url(
        "get_object",
        Params={"Bucket": IMAGE_BUCKET, "Key": key},
        ExpiresIn=PRESIGN_EXPIRES_IN,
    )
    return redirect(presigned, code=302)


if __name__ == "__main__":
    # Development only; production runs the app under gunicorn.
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
