"""Bearer-token auth for the local AI server.

The embedded server binds to 127.0.0.1 but is otherwise unauthenticated, so any
other local process that discovers the port has full access (see AUDIT.md H1).
To close that, the Flutter client generates a random token at spawn time, passes
it to the subprocess via the ``AISERVER_TOKEN`` env var, and attaches
``Authorization: Bearer <token>`` to every request.

When ``AISERVER_TOKEN`` is unset or empty (e.g. running ``python main.py`` in
development), auth is disabled so local dev and the existing test suite keep
working without changes.
"""
import hmac
import os
from typing import Optional

from fastapi import Header, HTTPException


def require_token(authorization: Optional[str] = Header(None)) -> None:
    """FastAPI dependency: reject requests without the expected bearer token.

    Reads the expected token from the environment on each call (it is fixed for
    the life of the process). Uses a constant-time comparison so a caller can't
    recover the token by timing responses.
    """
    expected = os.environ.get("AISERVER_TOKEN")
    if not expected:
        # No token configured — auth disabled (dev / backward compatible).
        return

    scheme, _, presented = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(presented, expected):
        raise HTTPException(status_code=401, detail="Unauthorized")
