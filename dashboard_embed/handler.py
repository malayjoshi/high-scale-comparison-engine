from __future__ import annotations

import json
import logging
import os
from typing import Any

import boto3


LOG = logging.getLogger("comparison-dashboard-embed")


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    try:
        return create_embed_response(event, boto3.client("quicksight"), os.environ)
    except Exception:
        LOG.exception("failed to generate QuickSight embed URL")
        return _response(502, {"message": "unable to generate dashboard link"}, os.environ)


def create_embed_response(
    event: dict[str, Any], quicksight: Any, environment: dict[str, str]
) -> dict[str, Any]:
    claims = event.get("requestContext", {}).get("authorizer", {}).get("claims", {})
    email = claims.get("email", "").strip().lower()
    readers = json.loads(environment["QUICKSIGHT_READERS"])
    user_arn = readers.get(email)
    if not user_arn:
        return _response(403, {"message": "dashboard access is not registered"}, environment)

    request = {
        "AwsAccountId": environment["AWS_ACCOUNT_ID"],
        "UserArn": user_arn,
        "SessionLifetimeInMinutes": 60,
        "ExperienceConfiguration": {
            "Dashboard": {"InitialDashboardId": environment["QUICKSIGHT_DASHBOARD_ID"]}
        },
    }
    allowed_domains = json.loads(environment["QUICKSIGHT_ALLOWED_DOMAINS"])
    if allowed_domains:
        request["AllowedDomains"] = allowed_domains

    result = quicksight.generate_embed_url_for_registered_user(**request)
    return _response(
        200,
        {"embed_url": result["EmbedUrl"], "redeem_within_seconds": 300},
        environment,
    )


def _response(status: int, body: dict[str, Any], environment: dict[str, str]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {
            "Access-Control-Allow-Origin": environment["DASHBOARD_APP_ORIGIN"],
            "Cache-Control": "no-store",
            "Content-Type": "application/json",
        },
        "body": json.dumps(body, separators=(",", ":")),
    }
