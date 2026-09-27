"""Query job status and pair progress from PostgreSQL."""

from __future__ import annotations

import json
import os
from typing import Any
from urllib.parse import unquote, urlparse
from uuid import UUID


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Return job and pair status from the database."""
    try:
        job_id = event["pathParameters"]["job_id"]
        if not job_id:
            return error_response(400, "job_id is required")

        # Validate UUID format
        try:
            UUID(job_id)
        except ValueError:
            return error_response(400, f"Invalid job_id format: {job_id}")

        # Try to fetch from database
        job_progress = get_job_progress(job_id)
        if not job_progress:
            return error_response(404, f"Job {job_id} not found")

        return success_response(job_progress)

    except KeyError as e:
        return error_response(400, f"Missing parameter: {e}")
    except Exception as e:
        print(f"Error fetching job {job_id}: {e}")
        return error_response(500, "Internal server error")


def get_job_progress(job_id: str) -> dict[str, Any] | None:
    """Query the database for job and pair status."""
    return _query_with_psycopg(job_id)


def _query_with_psycopg(job_id: str) -> dict[str, Any] | None:
    """Load credentials at runtime and return one consistent job snapshot."""
    import boto3
    import psycopg

    secret = boto3.client("secretsmanager").get_secret_value(
        SecretId=os.environ["DB_SECRET_ARN"]
    )
    credentials = json.loads(secret["SecretString"])
    db_config = {
        "host": os.environ.get("DB_HOST", "localhost"),
        "port": int(os.environ.get("DB_PORT", "5432")),
        "dbname": os.environ.get("DB_NAME", "comparison_engine"),
        "user": credentials["username"],
        "password": credentials["password"],
    }

    connection = psycopg.connect(
        host=db_config["host"],
        port=db_config["port"],
        dbname=db_config["dbname"],
        user=db_config["user"],
        password=db_config["password"],
        connect_timeout=10,
    )

    with connection:
        job_row = connection.execute(
            """
            SELECT job_id, status, timestamp_start, timestamp_end, expected_pair_count
            FROM comparison_jobs
            WHERE job_id = %s::UUID
            """,
            (job_id,),
        ).fetchone()

        if not job_row:
            return None

        job_uuid, status, started_at, completed_at, total_pairs = job_row

        pair_rows = connection.execute(
            """
            SELECT source_folder, destination_folder, status, timestamp_start,
                   comparison_completed_at, s3_location, error
            FROM comparison_results
            WHERE job_id = %s::UUID
            ORDER BY source_folder, destination_folder
            """,
            (job_id,),
        ).fetchall()

        completed_pairs = sum(1 for row in pair_rows if row[2] == "completed")
        failed_pairs = sum(1 for row in pair_rows if row[2] == "failed")
        s3 = boto3.client("s3")

        pairs = [
            {
                "sourceFolder": row[0],
                "destinationFolder": row[1],
                "status": row[2],
                "startedAt": row[3].isoformat() if row[3] else None,
                "completedAt": row[4].isoformat() if row[4] else None,
                "resultLocation": row[5],
                "resultUrl": _presigned_url(s3, row[5]) if row[5] else None,
                "error": row[6],
            }
            for row in pair_rows
        ]

        return {
            "job_id": str(job_uuid),
            "status": status,
            "total_pairs": total_pairs,
            "completed_pairs": completed_pairs,
            "failed_pairs": failed_pairs,
            "started_at": started_at.isoformat(),
            "completed_at": completed_at.isoformat() if completed_at else None,
            "pairs": pairs,
        }


def _presigned_url(s3: Any, location: str) -> str:
    """Turn a durable s3:// location into a short-lived browser URL."""
    parsed = urlparse(location)
    return s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": parsed.netloc, "Key": unquote(parsed.path.lstrip("/"))},
        ExpiresIn=900,
    )


def success_response(body: dict[str, Any]) -> dict[str, Any]:
    """Return a successful 200 response."""
    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": os.environ.get("FRONTEND_ORIGIN", "*"),
        },
        "body": json.dumps(body),
    }


def error_response(status_code: int, message: str) -> dict[str, Any]:
    """Return an error response."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": os.environ.get("FRONTEND_ORIGIN", "*"),
        },
        "body": json.dumps({"error": message}),
    }
