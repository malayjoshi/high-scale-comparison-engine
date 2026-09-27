"""Query job status and pair progress from PostgreSQL."""

from __future__ import annotations

import json
import os
from typing import Any
from datetime import datetime
from uuid import UUID

import boto3
import psycopg


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

        # Get database credentials from environment
        db_config = {
            "host": os.environ.get("DB_HOST", "localhost"),
            "port": int(os.environ.get("DB_PORT", "5432")),
            "dbname": os.environ.get("DB_NAME", "comparison_engine"),
            "user": os.environ.get("DB_USER", "comparison_admin"),
            "password": os.environ.get("DB_PASSWORD", ""),
        }

        job_progress = get_job_progress(job_id, db_config)
        if not job_progress:
            return error_response(404, f"Job {job_id} not found")

        return success_response(job_progress)

    except KeyError as e:
        return error_response(400, f"Missing parameter: {e}")
    except Exception as e:
        print(f"Error fetching job {job_id}: {e}")
        return error_response(500, "Internal server error")


def get_job_progress(job_id: str, db_config: dict[str, Any]) -> dict[str, Any] | None:
    """Query the database for job and pair status."""
    try:
        # Get database password from Secrets Manager if not provided
        password = db_config.get("password")
        if not password and os.environ.get("DB_SECRET_ARN"):
            password = _get_secret(os.environ["DB_SECRET_ARN"])

        connection = psycopg.connect(
            host=db_config["host"],
            port=db_config["port"],
            dbname=db_config["dbname"],
            user=db_config["user"],
            password=password,
            connect_timeout=10,
        )

        with connection:
            # Get job metadata
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

            # Get pair results
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

            # Count completed and failed pairs
            completed_pairs = sum(1 for row in pair_rows if row[2] == "completed")
            failed_pairs = sum(1 for row in pair_rows if row[2] == "failed")

            # Format pairs for response
            pairs = [
                {
                    "sourceFolder": row[0],
                    "destinationFolder": row[1],
                    "status": row[2],
                    "startedAt": row[3].isoformat() if row[3] else None,
                    "completedAt": row[4].isoformat() if row[4] else None,
                    "resultLocation": row[5],
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

    except Exception as e:
        print(f"Database error: {e}")
        raise


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


def _get_secret(secret_arn: str) -> str:
    """Retrieve database password from Secrets Manager."""
    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=secret_arn)
    secret = json.loads(response["SecretString"])
    return secret.get("password", "")
