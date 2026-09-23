from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from .request_model import ComparisonJob


@dataclass(frozen=True)
class DatabaseConfig:
    host: str
    port: int
    dbname: str
    user: str
    password: str


@dataclass(frozen=True)
class OutboxEvent:
    event_id: str
    event_type: str
    payload: dict[str, Any]


class JobRepository:
    def __init__(self, config: DatabaseConfig, worker_id: str, stale_after_seconds: int) -> None:
        self.config = config
        self.worker_id = worker_id
        self.stale_after_seconds = stale_after_seconds

    def _connect(self) -> psycopg.Connection:
        return psycopg.connect(
            host=self.config.host,
            port=self.config.port,
            dbname=self.config.dbname,
            user=self.config.user,
            password=self.config.password,
            connect_timeout=10,
        )

    def initialize(self) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS comparison_jobs (
                    job_id UUID PRIMARY KEY,
                    request_timestamp TIMESTAMPTZ NOT NULL,
                    timestamp_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    timestamp_end TIMESTAMPTZ,
                    user_id TEXT NOT NULL,
                    callback_id TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'started'
                        CHECK (status IN ('started', 'completed', 'failed')),
                    heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    worker_id TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL DEFAULT 1,
                    result_path TEXT,
                    error TEXT
                )
                """
            )
            connection.execute(
                "ALTER TABLE comparison_jobs ADD COLUMN IF NOT EXISTS callback_id TEXT"
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS comparison_results (
                    job_id UUID NOT NULL REFERENCES comparison_jobs(job_id) ON DELETE CASCADE,
                    source_folder TEXT NOT NULL,
                    destination_folder TEXT NOT NULL,
                    comparison_completed_at TIMESTAMPTZ NOT NULL,
                    s3_location TEXT NOT NULL,
                    PRIMARY KEY (job_id, source_folder, destination_folder)
                )
                """
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS comparison_outbox (
                    event_id UUID PRIMARY KEY,
                    job_id UUID NOT NULL REFERENCES comparison_jobs(job_id) ON DELETE CASCADE,
                    event_type TEXT NOT NULL,
                    payload JSONB NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    published_at TIMESTAMPTZ,
                    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    locked_at TIMESTAMPTZ,
                    locked_by TEXT,
                    last_error TEXT,
                    UNIQUE (job_id, event_type)
                )
                """
            )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS comparison_outbox_pending_idx
                ON comparison_outbox (next_attempt_at, created_at)
                WHERE published_at IS NULL
                """
            )

    def claim(self, job: ComparisonJob) -> str:
        with self._connect() as connection:
            inserted = connection.execute(
                """
                INSERT INTO comparison_jobs (
                    job_id, request_timestamp, user_id, callback_id, worker_id
                ) VALUES (%s, %s, %s, %s, %s)
                ON CONFLICT DO NOTHING
                RETURNING job_id
                """,
                (
                    job.job_id,
                    job.requested_at,
                    job.user_id,
                    job.callback_id,
                    self.worker_id,
                ),
            ).fetchone()
            if inserted:
                return "claimed"

            existing = connection.execute(
                """
                SELECT status, user_id, callback_id,
                       heartbeat_at < NOW() - (%s * INTERVAL '1 second') AS stale
                FROM comparison_jobs
                WHERE job_id = %s
                FOR UPDATE
                """,
                (self.stale_after_seconds, job.job_id),
            ).fetchone()
            if existing is None:
                raise RuntimeError(f"job disappeared while claiming: {job.job_id}")
            status, user_id, callback_id, stale = existing
            if user_id != job.user_id or callback_id != job.callback_id:
                raise ValueError(f"job {job.job_id} has conflicting ownership or callback")
            if status == "completed":
                return "completed"
            if status == "started" and not stale:
                return "busy"

            connection.execute(
                """
                UPDATE comparison_jobs
                SET status = 'started', timestamp_start = NOW(), timestamp_end = NULL,
                    heartbeat_at = NOW(), worker_id = %s,
                    attempt_count = attempt_count + 1, result_path = NULL, error = NULL
                WHERE job_id = %s
                """,
                (self.worker_id, job.job_id),
            )
            return "claimed"

    def heartbeat(self, job_id: str) -> None:
        with self._connect() as connection:
            cursor = connection.execute(
                """
                UPDATE comparison_jobs SET heartbeat_at = NOW()
                WHERE job_id = %s AND worker_id = %s AND status = 'started'
                """,
                (job_id, self.worker_id),
            )
            if cursor.rowcount != 1:
                raise RuntimeError(f"lost database claim for job {job_id}")

    def complete(
        self,
        job: ComparisonJob,
        result_path: str,
        result_locations: list[str],
    ) -> str:
        event_id = str(uuid.uuid4())
        with self._connect() as connection:
            completed = connection.execute(
                """
                UPDATE comparison_jobs
                SET status = 'completed', timestamp_end = NOW(), heartbeat_at = NOW(),
                    result_path = %s, error = NULL
                WHERE job_id = %s AND worker_id = %s AND status = 'started'
                RETURNING timestamp_end
                """,
                (result_path, job.job_id, self.worker_id),
            ).fetchone()
            if completed is None:
                raise RuntimeError(f"lost database claim for job {job.job_id}")

            payload = {
                "event_id": event_id,
                "job_id": job.job_id,
                "user_id": job.user_id,
                "callback_id": job.callback_id,
                "status": "completed",
                "completed_at": completed[0].isoformat(),
                "result_locations": result_locations,
            }
            inserted_event = connection.execute(
                """
                INSERT INTO comparison_outbox (
                    event_id, job_id, event_type, payload
                ) VALUES (%s, %s, %s, %s)
                ON CONFLICT (job_id, event_type) DO NOTHING
                RETURNING event_id
                """,
                (
                    event_id,
                    job.job_id,
                    "Comparison Job Completed",
                    Jsonb(payload),
                ),
            ).fetchone()
            if inserted_event is None:
                inserted_event = connection.execute(
                    """
                    SELECT event_id FROM comparison_outbox
                    WHERE job_id = %s AND event_type = %s
                    """,
                    (job.job_id, "Comparison Job Completed"),
                ).fetchone()
            if inserted_event is None:
                raise RuntimeError(f"failed to create outbox event for job {job.job_id}")
        return str(inserted_event[0])

    def record_result(
        self,
        job_id: str,
        source_folder: str,
        destination_folder: str,
        completed_at: datetime,
        s3_location: str,
    ) -> None:
        with self._connect() as connection:
            cursor = connection.execute(
                """
                INSERT INTO comparison_results (
                    job_id, source_folder, destination_folder,
                    comparison_completed_at, s3_location
                )
                SELECT %s, %s, %s, %s, %s
                WHERE EXISTS (
                    SELECT 1 FROM comparison_jobs
                    WHERE job_id = %s AND worker_id = %s AND status = 'started'
                )
                ON CONFLICT (job_id, source_folder, destination_folder)
                DO UPDATE SET
                    comparison_completed_at = EXCLUDED.comparison_completed_at,
                    s3_location = EXCLUDED.s3_location
                """,
                (
                    job_id,
                    source_folder,
                    destination_folder,
                    completed_at,
                    s3_location,
                    job_id,
                    self.worker_id,
                ),
            )
            if cursor.rowcount != 1:
                raise RuntimeError(f"lost database claim for job {job_id}")

    def fail(self, job_id: str, error: str) -> None:
        self._finish(job_id, "failed", error=error[:4000])

    def claim_outbox(self, limit: int = 10) -> list[OutboxEvent]:
        with self._connect() as connection:
            rows = connection.execute(
                """
                WITH available AS (
                    SELECT event_id
                    FROM comparison_outbox
                    WHERE published_at IS NULL
                      AND next_attempt_at <= NOW()
                      AND (locked_at IS NULL OR locked_at < NOW() - INTERVAL '5 minutes')
                    ORDER BY created_at
                    FOR UPDATE SKIP LOCKED
                    LIMIT %s
                )
                UPDATE comparison_outbox AS outbox
                SET locked_at = NOW(), locked_by = %s,
                    attempt_count = attempt_count + 1
                FROM available
                WHERE outbox.event_id = available.event_id
                RETURNING outbox.event_id, outbox.event_type, outbox.payload
                """,
                (limit, self.worker_id),
            ).fetchall()
        return [OutboxEvent(str(row[0]), row[1], row[2]) for row in rows]

    def mark_outbox_published(self, event_id: str) -> None:
        with self._connect() as connection:
            cursor = connection.execute(
                """
                UPDATE comparison_outbox
                SET published_at = NOW(), locked_at = NULL, locked_by = NULL,
                    last_error = NULL
                WHERE event_id = %s AND locked_by = %s AND published_at IS NULL
                """,
                (event_id, self.worker_id),
            )
            if cursor.rowcount != 1:
                raise RuntimeError(f"lost outbox claim for event {event_id}")

    def mark_outbox_failed(self, event_id: str, error: str) -> None:
        with self._connect() as connection:
            cursor = connection.execute(
                """
                UPDATE comparison_outbox
                SET locked_at = NULL, locked_by = NULL, last_error = %s,
                    next_attempt_at = NOW() +
                        (LEAST(300, attempt_count * attempt_count * 5) * INTERVAL '1 second')
                WHERE event_id = %s AND locked_by = %s AND published_at IS NULL
                """,
                (error[:4000], event_id, self.worker_id),
            )
            if cursor.rowcount != 1:
                raise RuntimeError(f"lost outbox claim for event {event_id}")

    def _finish(
        self,
        job_id: str,
        status: str,
        *,
        result_path: str | None = None,
        error: str | None = None,
    ) -> None:
        with self._connect() as connection:
            cursor = connection.execute(
                """
                UPDATE comparison_jobs
                SET status = %s, timestamp_end = NOW(), heartbeat_at = NOW(),
                    result_path = %s, error = %s
                WHERE job_id = %s AND worker_id = %s AND status = 'started'
                """,
                (status, result_path, error, job_id, self.worker_id),
            )
            if cursor.rowcount != 1:
                raise RuntimeError(f"lost database claim for job {job_id}")
