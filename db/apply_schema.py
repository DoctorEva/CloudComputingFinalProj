"""Apply the images schema on the query instance.

Invoked by deploy.sh over SSM, because the database lives in private subnets.
Connection settings come from the process environment when present, otherwise
from the query service's environment file or systemd unit. That keeps the
database password out of the SSM command, CloudTrail request parameters, and
command output.

Exit codes:
    0  every statement applied
    1  a statement failed
    2  the database could not be reached or is not configured
"""

import os
import re
import sys
import time

import pymysql

ENV_PATH = "/etc/query/query.env"
UNIT_PATH = "/etc/systemd/system/query.service"
REQUIRED = ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD")
CONNECT_ATTEMPTS = 3
CONNECT_DELAY_SECONDS = 5


def _read_env_file(path):
    env = {}
    try:
        with open(path) as handle:
            for line in handle:
                key, sep, value = line.strip().partition("=")
                if sep and key and not key.startswith("#"):
                    env[key] = value.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return env


def _read_unit_env(path):
    env = {}
    pattern = re.compile(r"\s*Environment=([A-Za-z_][A-Za-z0-9_]*)=(.*)")
    try:
        with open(path) as handle:
            for line in handle:
                match = pattern.match(line)
                if match:
                    env[match.group(1)] = match.group(2).strip()
    except FileNotFoundError:
        pass
    return env


def settings():
    file_env = _read_env_file(ENV_PATH)
    unit_env = _read_unit_env(UNIT_PATH)
    resolved = {}
    for key in ("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"):
        resolved[key] = (
            os.environ.get(key) or file_env.get(key) or unit_env.get(key)
        )

    missing = [key for key in REQUIRED if not resolved.get(key)]
    if missing:
        print(
            "missing database settings: %s" % ", ".join(missing),
            file=sys.stderr,
        )
        raise SystemExit(2)

    resolved["DB_PORT"] = int(resolved.get("DB_PORT") or 3306)
    return resolved


def read_statements(path):
    """Return the file's statements, ignoring full-line -- comments.

    Statements are split on ';', so a file must not contain a semicolon inside
    a string literal or a routine body.
    """
    with open(path) as handle:
        raw = handle.read()

    lines = [
        line for line in raw.splitlines()
        if not line.strip().startswith("--")
    ]
    statements = []
    for chunk in "\n".join(lines).split(";"):
        chunk = chunk.strip()
        if chunk:
            statements.append(chunk)

    if not statements:
        raise SystemExit("no statements found in %s" % path)
    return statements


def connect(config):
    last_error = None
    for attempt in range(1, CONNECT_ATTEMPTS + 1):
        try:
            return pymysql.connect(
                host=config["DB_HOST"],
                port=config["DB_PORT"],
                user=config["DB_USER"],
                password=config["DB_PASSWORD"],
                database=config["DB_NAME"],
                connect_timeout=5,
                cursorclass=pymysql.cursors.DictCursor,
            )
        except pymysql.err.OperationalError as exc:
            last_error = exc
            if attempt < CONNECT_ATTEMPTS:
                print(
                    "connection attempt %d/%d failed, retrying: %s"
                    % (attempt, CONNECT_ATTEMPTS, exc),
                    file=sys.stderr,
                )
                time.sleep(CONNECT_DELAY_SECONDS)

    print(
        "could not connect to %s:%s: %s"
        % (config["DB_HOST"], config["DB_PORT"], last_error),
        file=sys.stderr,
    )
    return None


def main(argv):
    if len(argv) != 2:
        raise SystemExit("usage: apply_schema.py <schema.sql>")

    statements = read_statements(argv[1])
    connection = connect(settings())
    if connection is None:
        return 2

    try:
        with connection.cursor() as cursor:
            for statement in statements:
                try:
                    cursor.execute(statement)
                except pymysql.MySQLError as exc:
                    print(
                        "statement failed: %s\n%s" % (statement, exc),
                        file=sys.stderr,
                    )
                    return 1
        connection.commit()
    finally:
        connection.close()

    print("applied %d statement(s) from %s" % (len(statements), argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
