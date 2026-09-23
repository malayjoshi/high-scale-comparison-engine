from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

import psycopg

from .request_model import ComparisonJob


@dataclass(frozen=True)
class DatabaseConfig:
    host: str
    port: int
    dbname: str
    user: str
    password: str


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

    def claim(self, job: ComparisonJob) -> str:
        with self._connect() as connection:
            inserted = connection.execute(
                """
                INSERT INTO comparison_jobs (
                    job_id, request_timestamp, user_id, worker_id
                ) VALUES (%s, %s, %s, %s)
                ON CONFLICT DO NOTHING
                RETURNING job_id
                """,
                (job.job_id, job.requested_at, job.user_id, self.worker_id),
            ).fetchone()
            if inserted:
                return "claimed"

            existing = connection.execute(
                """
                SELECT status, user_id,
                       heartbeat_at < NOW() - (%s * INTERVAL '1 second') AS stale
                FROM comparison_jobs
                WHERE job_id = %s
                FOR UPDATE
                """,
                (self.stale_after_seconds, job.job_id),
            ).fetchone()
            if existing is None:
                raise RuntimeError(f"job disappeared while claiming: {job.job_id}")
            status, user_id, stale = existing
            if user_id != job.user_id:
                raise ValueError(f"job {job.job_id} belongs to another user")
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

    def complete(self, job_id: str, result_path: str) -> None:
        self._finish(job_id, "completed", result_path=result_path)

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
