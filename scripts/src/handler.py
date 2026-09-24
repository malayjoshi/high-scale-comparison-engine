from __future__ import annotations

import json
import logging
import os
import signal
import socket
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from types import FrameType
from typing import Any

import boto3

from .outbox import OutboxDispatcher
from .repo import DatabaseConfig, JobRepository
from .request_model import ComparisonJob
from .result_store import S3ResultStore
from .service import ComparisonService


LOG = logging.getLogger("comparison-worker")


@dataclass(frozen=True)
class Settings:
    queue_url: str
    database_endpoint: str
    database_name: str
    database_secret_arn: str
    results_bucket: str
    completion_queue_url: str
    data_root: Path
    result_root: Path
    max_workers: int
    visibility_timeout: int
    heartbeat_interval: int

    @classmethod
    def from_environment(cls) -> "Settings":
        return cls(
            queue_url=_required("COMPARISON_QUEUE_URL"),
            database_endpoint=_required("COMPARISON_DATABASE_ENDPOINT"),
            database_name=os.getenv("COMPARISON_DATABASE_NAME", "comparison_engine"),
            database_secret_arn=_required("COMPARISON_DATABASE_SECRET_ARN"),
            results_bucket=_required("COMPARISON_RESULTS_BUCKET"),
            completion_queue_url=_required("COMPARISON_COMPLETION_QUEUE_URL"),
            data_root=Path(os.getenv("COMPARISON_DATA_ROOT", "/mnt/comparison-engine/dummy_data")),
            result_root=Path(os.getenv("COMPARISON_RESULT_ROOT", "/var/tmp/comparison-engine")),
            max_workers=int(os.getenv("COMPARISON_MAX_WORKERS", str(min(32, (os.cpu_count() or 1) * 2)))),
            visibility_timeout=int(os.getenv("COMPARISON_VISIBILITY_TIMEOUT", "300")),
            heartbeat_interval=int(os.getenv("COMPARISON_HEARTBEAT_INTERVAL", "60")),
        )


class VisibilityHeartbeat:
    def __init__(
        self,
        sqs: Any,
        queue_url: str,
        receipt_handle: str,
        visibility_timeout: int,
        interval: int,
        repository: JobRepository,
        job: ComparisonJob,
    ) -> None:
        self.sqs = sqs
        self.queue_url = queue_url
        self.receipt_handle = receipt_handle
        self.visibility_timeout = visibility_timeout
        self.interval = interval
        self.repository = repository
        self.job = job
        self.stop = threading.Event()
        self.error: Exception | None = None
        self.thread = threading.Thread(
            target=self._run,
            name=f"visibility-{job.job_id}",
            daemon=True,
        )

    def __enter__(self) -> "VisibilityHeartbeat":
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.stop.set()
        self.thread.join()

    def raise_if_failed(self) -> None:
        if self.error:
            raise RuntimeError("visibility heartbeat failed") from self.error

    def _run(self) -> None:
        while not self.stop.wait(self.interval):
            try:
                self.sqs.change_message_visibility(
                    QueueUrl=self.queue_url,
                    ReceiptHandle=self.receipt_handle,
                    VisibilityTimeout=self.visibility_timeout,
                )
                self.repository.heartbeat(self.job)
            except Exception as exc:  # reported to the processing thread
                self.error = exc
                self.stop.set()


class Worker:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        session = boto3.Session()
        self.sqs = session.client("sqs")
        self.result_store = S3ResultStore(session.client("s3"), settings.results_bucket)
        secret = session.client("secretsmanager").get_secret_value(
            SecretId=settings.database_secret_arn
        )
        credentials = json.loads(secret["SecretString"])
        host, separator, port = settings.database_endpoint.rpartition(":")
        if not separator:
            host, port = settings.database_endpoint, "5432"
        database = DatabaseConfig(
            host=host,
            port=int(port),
            dbname=settings.database_name,
            user=credentials["username"],
            password=credentials["password"],
        )
        self.repository = JobRepository(
            database,
            worker_id=socket.gethostname(),
            stale_after_seconds=settings.visibility_timeout * 2,
        )
        self.comparison = ComparisonService(
            settings.data_root,
            settings.result_root,
            settings.max_workers,
        )
        self.outbox = OutboxDispatcher(
            self.repository,
            self.sqs,
            settings.completion_queue_url,
        )
        self.stopping = False

    def run(self) -> None:
        self.repository.initialize()
        self.outbox.start()
        try:
            while not self.stopping:
                try:
                    response = self.sqs.receive_message(
                        QueueUrl=self.settings.queue_url,
                        MaxNumberOfMessages=1,
                        WaitTimeSeconds=20,
                        VisibilityTimeout=self.settings.visibility_timeout,
                    )
                    for message in response.get("Messages", []):
                        self._handle(message)
                except Exception:
                    LOG.exception("failed to receive or process a message")
                    time.sleep(5)
        finally:
            self.outbox.stop()

    def stop(self, _signal: int, _frame: FrameType | None) -> None:
        self.stopping = True

    def _handle(self, message: dict[str, str]) -> None:
        receipt_handle = message["ReceiptHandle"]
        job: ComparisonJob | None = None
        claimed = False
        try:
            job = ComparisonJob.from_message(message["Body"])
            claim = self.repository.claim(job)
            if claim == "completed":
                self._delete(receipt_handle)
                return
            if claim == "busy":
                self._release(receipt_handle, 60)
                return
            claimed = True

            heartbeat = VisibilityHeartbeat(
                self.sqs,
                self.settings.queue_url,
                receipt_handle,
                self.settings.visibility_timeout,
                self.settings.heartbeat_interval,
                self.repository,
                job,
            )
            with heartbeat:
                folder_result = self.comparison.compare_folders(job.pair)
                completed_at = datetime.now(timezone.utc)
                s3_location = self.result_store.put_folder_result(
                    job,
                    folder_result,
                    completed_at,
                )
                heartbeat.raise_if_failed()
                result = self.comparison.build_result(job, folder_result)
                result_path = self.comparison.save(job, result)
                heartbeat.raise_if_failed()
                self.repository.complete(job, str(result_path), s3_location)
        except Exception as exc:
            LOG.exception("comparison job failed")
            if claimed and job is not None:
                try:
                    self.repository.fail(job, str(exc))
                except Exception:
                    LOG.exception("failed to mark job as failed")
            self._release(receipt_handle, 0)
            return

        self._delete(receipt_handle)

    def _delete(self, receipt_handle: str) -> None:
        self.sqs.delete_message(QueueUrl=self.settings.queue_url, ReceiptHandle=receipt_handle)

    def _release(self, receipt_handle: str, timeout: int) -> None:
        try:
            self.sqs.change_message_visibility(
                QueueUrl=self.settings.queue_url,
                ReceiptHandle=receipt_handle,
                VisibilityTimeout=timeout,
            )
        except Exception:
            LOG.exception("failed to release SQS message")


def _required(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise ValueError(f"{name} is required")
    return value


def main() -> None:
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    worker = Worker(Settings.from_environment())
    signal.signal(signal.SIGTERM, worker.stop)
    signal.signal(signal.SIGINT, worker.stop)
    worker.run()


if __name__ == "__main__":
    main()
