"""PostgreSQL-backed job claims, progress tracking, and completion outbox."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
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
    """Coordinate many workers without allowing the same pair to run concurrently."""
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
                    expected_pair_count INTEGER NOT NULL CHECK (expected_pair_count > 0),
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
                "ALTER TABLE comparison_jobs ADD COLUMN IF NOT EXISTS expected_pair_count INTEGER"
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS comparison_results (
                    job_id UUID NOT NULL REFERENCES comparison_jobs(job_id) ON DELETE CASCADE,
                    source_folder TEXT NOT NULL,
                    destination_folder TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'started'
                        CHECK (status IN ('started', 'completed', 'failed')),
                    timestamp_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    comparison_completed_at TIMESTAMPTZ,
                    heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    worker_id TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL DEFAULT 1,
                    result_path TEXT,
                    s3_location TEXT,
                    error TEXT,
                    PRIMARY KEY (job_id, source_folder, destination_folder)
                )
                """
            )
            for statement in (
                "ALTER TABLE comparison_results ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'completed'",
                "ALTER TABLE comparison_results ADD COLUMN IF NOT EXISTS timestamp_start TIMESTAMPTZ NOT NULL DEFAULT NOW()",
                "ALTER TABLE comparison_results ADD COLUMN IF NOT EXISTS heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT NOW()",
                "ALTER TABLE comparison_results ADD COLUMN IF NOT EXISTS worker_id TEXT NOT NULL DEFAULT ''",
                "ALTER TABLE comparison_results ADD COLUMN IF NOT EXISTS attempt_count INTEGER NOT NULL DEFAULT 1",
                "ALTER TABLE comparison_results ADD COLUMN IF NOT EXISTS result_path TEXT",
                "ALTER TABLE comparison_results ADD COLUMN IF NOT EXISTS error TEXT",
                "ALTER TABLE comparison_results ALTER COLUMN comparison_completed_at DROP NOT NULL",
                "ALTER TABLE comparison_results ALTER COLUMN s3_location DROP NOT NULL",
            ):
                connection.execute(statement)
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
        """Return ``claimed``, ``busy``, or ``completed`` for an idempotent task."""
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO comparison_jobs (
                    job_id, request_timestamp, expected_pair_count, user_id, callback_id, worker_id
                ) VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT DO NOTHING
                """,
                (
                    job.job_id,
                    job.requested_at,
                    job.expected_pair_count,
                    job.user_id,
                    job.callback_id,
                    self.worker_id,
                ),
            )

            parent = connection.execute(
                """
                SELECT status, user_id, callback_id, expected_pair_count
                FROM comparison_jobs
                WHERE job_id = %s
                FOR UPDATE
                """,
                (job.job_id,),
            ).fetchone()
            if parent is None:
                raise RuntimeError(f"job disappeared while claiming: {job.job_id}")
            parent_status, user_id, callback_id, expected_pair_count = parent
            if user_id != job.user_id or callback_id != job.callback_id:
                raise ValueError(f"job {job.job_id} has conflicting ownership or callback")
            if expected_pair_count != job.expected_pair_count:
                raise ValueError(f"job {job.job_id} has conflicting total_expected_pairs")

            existing = connection.execute(
                """
                SELECT status,
                       heartbeat_at < NOW() - (%s * INTERVAL '1 second') AS stale
                FROM comparison_results
                WHERE job_id = %s AND source_folder = %s AND destination_folder = %s
                FOR UPDATE
                """,
                (
                    self.stale_after_seconds,
                    job.job_id,
                    job.pair.source_folder,
                    job.pair.destination_folder,
                ),
            ).fetchone()
            if existing is None:
                if parent_status == "completed":
                    raise ValueError(f"job {job.job_id} is already completed")
                pair_count = connection.execute(
                    "SELECT COUNT(*) FROM comparison_results WHERE job_id = %s",
                    (job.job_id,),
                ).fetchone()[0]
                if pair_count >= job.expected_pair_count:
                    raise ValueError(f"job {job.job_id} already has all expected pairs")
                connection.execute(
                    """
                    INSERT INTO comparison_results (
                        job_id, source_folder, destination_folder, status, worker_id
                    ) VALUES (%s, %s, %s, 'started', %s)
                    """,
                    (
                        job.job_id,
                        job.pair.source_folder,
                        job.pair.destination_folder,
                        self.worker_id,
                    ),
                )
                return "claimed"

            status, stale = existing
            if status == "completed":
                return "completed"
            if status == "started" and not stale:
                return "busy"

            connection.execute(
                """
                UPDATE comparison_results
                SET status = 'started', timestamp_start = NOW(), comparison_completed_at = NULL,
                    heartbeat_at = NOW(), worker_id = %s,
                    attempt_count = attempt_count + 1, result_path = NULL,
                    s3_location = NULL, error = NULL
                WHERE job_id = %s AND source_folder = %s AND destination_folder = %s
                """,
                (
                    self.worker_id,
                    job.job_id,
                    job.pair.source_folder,
                    job.pair.destination_folder,
                ),
            )
            return "claimed"

    def heartbeat(self, job: ComparisonJob) -> None:
        with self._connect() as connection:
            cursor = connection.execute(
                """
                UPDATE comparison_results SET heartbeat_at = NOW()
                WHERE job_id = %s AND source_folder = %s AND destination_folder = %s
                  AND worker_id = %s AND status = 'started'
                """,
                (
                    job.job_id,
                    job.pair.source_folder,
                    job.pair.destination_folder,
                    self.worker_id,
                ),
            )
            if cursor.rowcount != 1:
                raise RuntimeError(f"lost database claim for job {job.job_id}")

    def complete(
        self,
        job: ComparisonJob,
        result_path: str,
        result_location: str,
    ) -> str | None:
        """Commit the pair result and final completion event in one transaction."""
        event_id = str(uuid.uuid4())
        with self._connect() as connection:
            parent = connection.execute(
                """
                SELECT status, expected_pair_count
                FROM comparison_jobs
                WHERE job_id = %s
                FOR UPDATE
                """,
                (job.job_id,),
            ).fetchone()
            if parent is None:
                raise RuntimeError(f"job disappeared while completing: {job.job_id}")

            completed_pair = connection.execute(
                """
                UPDATE comparison_results
                SET status = 'completed', comparison_completed_at = NOW(), heartbeat_at = NOW(),
                    result_path = %s, s3_location = %s, error = NULL
                WHERE job_id = %s AND source_folder = %s AND destination_folder = %s
                  AND worker_id = %s AND status = 'started'
                RETURNING comparison_completed_at
                """,
                (
                    result_path,
                    result_location,
                    job.job_id,
                    job.pair.source_folder,
                    job.pair.destination_folder,
                    self.worker_id,
                ),
            ).fetchone()
            if completed_pair is None:
                raise RuntimeError(f"lost database claim for job {job.job_id}")

            completed_count = connection.execute(
                """
                SELECT COUNT(*) FROM comparison_results
                WHERE job_id = %s AND status = 'completed'
                """,
                (job.job_id,),
            ).fetchone()[0]
            if completed_count != parent[1] or parent[0] == "completed":
                return None

            completed_job = connection.execute(
                """
                UPDATE comparison_jobs
                SET status = 'completed', timestamp_end = NOW()
                WHERE job_id = %s AND status = 'started'
                RETURNING timestamp_end
                """,
                (job.job_id,),
            ).fetchone()
            if completed_job is None:
                raise RuntimeError(f"failed to complete job {job.job_id}")
            result_locations = [
                row[0]
                for row in connection.execute(
                    """
                    SELECT s3_location FROM comparison_results
                    WHERE job_id = %s AND status = 'completed'
                    ORDER BY source_folder, destination_folder
                    """,
                    (job.job_id,),
                ).fetchall()
            ]

            payload = {
                "event_id": event_id,
                "job_id": job.job_id,
                "user_id": job.user_id,
                "callback_id": job.callback_id,
                "status": "completed",
                "completed_at": completed_job[0].isoformat(),
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

    def fail(self, job: ComparisonJob, error: str) -> None:
        with self._connect() as connection:
            cursor = connection.execute(
                """
                UPDATE comparison_results
                SET status = 'failed', comparison_completed_at = NOW(), heartbeat_at = NOW(),
                    error = %s
                WHERE job_id = %s AND source_folder = %s AND destination_folder = %s
                  AND worker_id = %s AND status = 'started'
                """,
                (
                    error[:4000],
                    job.job_id,
                    job.pair.source_folder,
                    job.pair.destination_folder,
                    self.worker_id,
                ),
            )
            if cursor.rowcount != 1:
                raise RuntimeError(f"lost database claim for job {job.job_id}")

    def claim_outbox(self, limit: int = 10) -> list[OutboxEvent]:
        """Lock a small batch without blocking other dispatchers."""
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
