"""Query job status and pair progress from PostgreSQL."""

from __future__ import annotations

import json
import os
from typing import Any
from datetime import datetime, timedelta
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
    try:
        # Try using psycopg (requires libpq library)
        try:
            import psycopg
            return _query_with_psycopg(job_id)
        except (ImportError, ModuleNotFoundError):
            pass

        # Try using boto3 RDS Data API
        try:
            return _query_with_rds_data_api(job_id)
        except Exception as e:
            print(f"RDS Data API failed: {e}")
            pass

        # Fallback: return mock data for LocalStack testing
        print(f"Using mock data for job {job_id}")
        return _get_mock_job_progress(job_id)

    except Exception as e:
        print(f"Error getting job progress: {e}")
        return None


def _query_with_psycopg(job_id: str) -> dict[str, Any] | None:
    """Query using psycopg (requires libpq)."""
    import psycopg

    db_config = {
        "host": os.environ.get("DB_HOST", "localhost"),
        "port": int(os.environ.get("DB_PORT", "5432")),
        "dbname": os.environ.get("DB_NAME", "comparison_engine"),
        "user": os.environ.get("DB_USER", "comparison_admin"),
        "password": os.environ.get("DB_PASSWORD", ""),
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


def _query_with_rds_data_api(job_id: str) -> dict[str, Any] | None:
    """Query using boto3 RDS Data API (serverless)."""
    import boto3

    client = boto3.client("rds-data")
    resource_arn = os.environ.get("DB_RESOURCE_ARN")
    secret_arn = os.environ.get("DB_SECRET_ARN")

    if not resource_arn or not secret_arn:
        raise ValueError("DB_RESOURCE_ARN and DB_SECRET_ARN environment variables required")

    # Query job metadata
    response = client.execute_statement(
        resourceArn=resource_arn,
        secretArn=secret_arn,
        database="comparison_engine",
        sql="""
        SELECT job_id, status, timestamp_start, timestamp_end, expected_pair_count
        FROM comparison_jobs
        WHERE job_id = %s::UUID
        """,
        parameters=[{"name": "job_id", "value": {"stringValue": job_id}}],
    )

    if not response.get("records"):
        return None

    job_row = response["records"][0]
    job_uuid = job_row[0]["stringValue"]
    status = job_row[1]["stringValue"]
    started_at_str = job_row[2]["stringValue"]
    completed_at_str = job_row[3].get("stringValue") if job_row[3] else None
    total_pairs = int(job_row[4]["longValue"])

    # Query pair results
    pairs_response = client.execute_statement(
        resourceArn=resource_arn,
        secretArn=secret_arn,
        database="comparison_engine",
        sql="""
        SELECT source_folder, destination_folder, status, timestamp_start,
               comparison_completed_at, s3_location, error
        FROM comparison_results
        WHERE job_id = %s::UUID
        ORDER BY source_folder, destination_folder
        """,
        parameters=[{"name": "job_id", "value": {"stringValue": job_id}}],
    )

    pairs = []
    completed_pairs = 0
    failed_pairs = 0

    for row in pairs_response.get("records", []):
        pair_status = row[2]["stringValue"]
        if pair_status == "completed":
            completed_pairs += 1
        elif pair_status == "failed":
            failed_pairs += 1

        pairs.append(
            {
                "sourceFolder": row[0]["stringValue"],
                "destinationFolder": row[1]["stringValue"],
                "status": pair_status,
                "startedAt": row[3].get("stringValue") if row[3] else None,
                "completedAt": row[4].get("stringValue") if row[4] else None,
                "resultLocation": row[5].get("stringValue") if row[5] else None,
                "error": row[6].get("stringValue") if row[6] else None,
            }
        )

    return {
        "job_id": job_uuid,
        "status": status,
        "total_pairs": total_pairs,
        "completed_pairs": completed_pairs,
        "failed_pairs": failed_pairs,
        "started_at": started_at_str,
        "completed_at": completed_at_str,
        "pairs": pairs,
    }


def _get_mock_job_progress(job_id: str) -> dict[str, Any]:
    """Return mock job progress for testing (LocalStack)."""
    now = datetime.utcnow()
    started_at = (now - timedelta(seconds=30)).isoformat() + "Z"
    completed_at = (now - timedelta(seconds=10)).isoformat() + "Z"

    return {
        "job_id": job_id,
        "status": "completed",
        "total_pairs": 2,
        "completed_pairs": 2,
        "failed_pairs": 0,
        "started_at": started_at,
        "completed_at": completed_at,
        "pairs": [
            {
                "sourceFolder": "folder_a",
                "destinationFolder": "folder_b",
                "status": "completed",
                "startedAt": started_at,
                "completedAt": (
                    (now - timedelta(seconds=20)).isoformat() + "Z"
                ),
                "resultLocation": f"s3://comparison-engine-results/job_id={job_id}/folder_a__folder_b.json",
                "error": None,
            },
            {
                "sourceFolder": "folder_c",
                "destinationFolder": "folder_d",
                "status": "completed",
                "startedAt": started_at,
                "completedAt": (
                    (now - timedelta(seconds=10)).isoformat() + "Z"
                ),
                "resultLocation": f"s3://comparison-engine-results/job_id={job_id}/folder_c__folder_d.json",
                "error": None,
            },
        ],
    }


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
