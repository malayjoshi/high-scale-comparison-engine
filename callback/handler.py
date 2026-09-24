"""Deliver completed-job events only to callbacks registered in DynamoDB."""

from __future__ import annotations

import json
import logging
import os
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

import boto3


LOG = logging.getLogger("comparison-callback")
LOCAL_HOSTS = {"localhost", "127.0.0.1", "host.docker.internal"}


class RejectRedirects(HTTPRedirectHandler):
    """Keep an approved callback from redirecting Lambda to another host."""
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        raise HTTPError(req.full_url, code, "callback redirects are disabled", headers, fp)


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, list[dict[str, str]]]:
    """Return partial batch failures so SQS retries only unsuccessful callbacks."""
    table = boto3.resource("dynamodb").Table(os.environ["CALLBACK_CLIENTS_TABLE"])
    opener = build_opener(RejectRedirects())
    failures = []

    for record in event.get("Records", []):
        try:
            deliver_callback(json.loads(record["body"]), table, opener)
        except Exception:
            LOG.exception("callback delivery failed for SQS message %s", record["messageId"])
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}


def deliver_callback(message: dict[str, Any], table: Any, opener: Any) -> None:
    """Resolve an allow-listed callback ID and POST one completion event."""
    event_id = _required_string(message, "event_id")
    detail = message.get("detail")
    if not isinstance(detail, dict):
        raise ValueError("completion message detail must be an object")
    callback_id = _required_string(detail, "callback_id")

    item = table.get_item(Key={"callback_id": callback_id}, ConsistentRead=True).get("Item")
    if not item or not item.get("enabled", False):
        raise ValueError(f"callback {callback_id!r} is not enabled")

    callback_url = item["callback_url"]
    _validate_url(callback_url)
    request = Request(
        callback_url,
        data=json.dumps(message, separators=(",", ":")).encode(),
        headers={
            "Content-Type": "application/json",
            "X-Comparison-Event-Id": event_id,
        },
        method="POST",
    )
    with opener.open(request, timeout=10) as response:
        if not 200 <= response.status < 300:
            raise RuntimeError(f"callback returned HTTP {response.status}")


def _required_string(value: dict[str, Any], key: str) -> str:
    result = value.get(key)
    if not isinstance(result, str) or not result:
        raise ValueError(f"completion message {key} is required")
    return result


def _validate_url(url: str) -> None:
    parsed = urlparse(url)
    if parsed.username or parsed.password or not parsed.hostname:
        raise ValueError("invalid callback URL")
    if parsed.scheme == "https":
        return
    if parsed.scheme == "http" and parsed.hostname in LOCAL_HOSTS:
        return
    raise ValueError("callback URL must use HTTPS unless it targets a local development host")
