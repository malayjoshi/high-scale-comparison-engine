"""Measure local worker throughput against LocalStack and PostgreSQL.

Each trial uses temporary queues, a bucket, and a database secret. The job
tables are truncated between trials so worker counts see the same workload.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import tempfile
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import boto3
import psycopg

from src.repo import DatabaseConfig, JobRepository


@dataclass(frozen=True)
class TrialResult:
    workers: int
    jobs: int
    seconds: float

    @property
    def jobs_per_second(self) -> float:
        return self.jobs / self.seconds


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark local comparison workers against LocalStack and PostgreSQL."
    )
    parser.add_argument("--workers", default="1,2,4", help="Comma-separated worker counts")
    parser.add_argument("--jobs", type=int, default=12, help="Jobs per trial")
    parser.add_argument("--timeout", type=int, default=600, help="Seconds allowed per trial")
    parser.add_argument("--postgres-host", default="127.0.0.1")
    parser.add_argument("--postgres-port", type=int, default=55432)
    parser.add_argument("--postgres-database", default="comparison_engine")
    parser.add_argument("--postgres-user", default="postgres")
    parser.add_argument("--postgres-password", default="")
    parser.add_argument(
        "--data-root",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "dummy_data",
    )
    return parser.parse_args()


def folder_label(index: int) -> str:
    label = ""
    value = index + 1
    while value:
        value, remainder = divmod(value - 1, 26)
        label = chr(ord("a") + remainder) + label
    return f"folder_{label}"


class Benchmark:
    """Create an isolated workload, run worker processes, and clean it up."""
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.root = Path(__file__).resolve().parents[1]
        self.python = self.root / "scripts" / ".venv" / "bin" / "python"
        self.run_id = uuid.uuid4().hex[:10]
        self.session = boto3.Session()
        self.sqs = self.session.client("sqs")
        self.s3 = self.session.client("s3")
        self.secrets = self.session.client("secretsmanager")
        self.bucket = f"comparison-benchmark-{self.run_id}"
        self.secret_name = f"comparison-benchmark-{self.run_id}-database"
        self.secret_arn = ""
        self.created_queues: list[str] = []
        self.database = DatabaseConfig(
            host=args.postgres_host,
            port=args.postgres_port,
            dbname=args.postgres_database,
            user=args.postgres_user,
            password=args.postgres_password,
        )

    def setup(self) -> None:
        if not self.python.is_file():
            raise RuntimeError(f"worker Python interpreter not found: {self.python}")
        if not self.args.data_root.is_dir():
            raise RuntimeError(f"dummy-data directory not found: {self.args.data_root}")

        repository = JobRepository(self.database, "benchmark-controller", 120)
        repository.initialize()
        self.s3.create_bucket(
            Bucket=self.bucket,
            CreateBucketConfiguration={"LocationConstraint": self.session.region_name},
        )
        secret = self.secrets.create_secret(
            Name=self.secret_name,
            SecretString=json.dumps(
                {"username": self.args.postgres_user, "password": self.args.postgres_password}
            ),
        )
        self.secret_arn = secret["ARN"]

    def cleanup(self) -> None:
        for queue_url in self.created_queues:
            try:
                self.sqs.delete_queue(QueueUrl=queue_url)
            except Exception:
                pass
        try:
            response = self.s3.list_objects_v2(Bucket=self.bucket)
            objects = [{"Key": item["Key"]} for item in response.get("Contents", [])]
            if objects:
                self.s3.delete_objects(Bucket=self.bucket, Delete={"Objects": objects})
            self.s3.delete_bucket(Bucket=self.bucket)
        except Exception:
            pass
        if self.secret_arn:
            try:
                self.secrets.delete_secret(
                    SecretId=self.secret_arn,
                    ForceDeleteWithoutRecovery=True,
                )
            except Exception:
                pass

    def trial(self, worker_count: int, jobs: int, timeout: int) -> TrialResult:
        self._reset_database()
        input_queue = self._create_queue(f"comparison-benchmark-{self.run_id}-{worker_count}-input")
        completion_queue = self._create_queue(
            f"comparison-benchmark-{self.run_id}-{worker_count}-completion"
        )

        with tempfile.TemporaryDirectory(prefix=f"comparison-workers-{worker_count}-") as temp:
            processes, logs = self._start_workers(
                worker_count,
                input_queue,
                completion_queue,
                Path(temp),
            )
            try:
                time.sleep(1)
                failed = [process for process in processes if process.poll() is not None]
                if failed:
                    raise RuntimeError(self._failure_message(processes, logs))

                started = time.perf_counter()
                self._enqueue_jobs(input_queue, jobs)
                self._wait_for_jobs(jobs, timeout, processes, logs)
                elapsed = time.perf_counter() - started
            finally:
                self._stop_workers(processes)
                for handle in logs:
                    handle.close()

        return TrialResult(worker_count, jobs, elapsed)

    def _create_queue(self, name: str) -> str:
        response = self.sqs.create_queue(QueueName=name)
        queue_url = response["QueueUrl"]
        self.created_queues.append(queue_url)
        return queue_url

    def _reset_database(self) -> None:
        with psycopg.connect(
            host=self.database.host,
            port=self.database.port,
            dbname=self.database.dbname,
            user=self.database.user,
            password=self.database.password,
        ) as connection:
            connection.execute(
                "TRUNCATE comparison_results, comparison_outbox, comparison_jobs CASCADE"
            )

    def _start_workers(
        self,
        count: int,
        input_queue: str,
        completion_queue: str,
        temp: Path,
    ) -> tuple[list[subprocess.Popen[bytes]], list[object]]:
        processes: list[subprocess.Popen[bytes]] = []
        logs: list[object] = []
        for index in range(count):
            result_root = temp / f"worker-{index}"
            log = (temp / f"worker-{index}.log").open("wb")
            environment = os.environ.copy()
            environment.update(
                {
                    "COMPARISON_QUEUE_URL": input_queue,
                    "COMPARISON_DATABASE_ENDPOINT": (
                        f"{self.database.host}:{self.database.port}"
                    ),
                    "COMPARISON_DATABASE_NAME": self.database.dbname,
                    "COMPARISON_DATABASE_SECRET_ARN": self.secret_arn,
                    "COMPARISON_RESULTS_BUCKET": self.bucket,
                    "COMPARISON_COMPLETION_QUEUE_URL": completion_queue,
                    "COMPARISON_DATA_ROOT": str(self.args.data_root.resolve()),
                    "COMPARISON_RESULT_ROOT": str(result_root),
                    "COMPARISON_MAX_WORKERS": "1",
                    "COMPARISON_VISIBILITY_TIMEOUT": "120",
                    "COMPARISON_HEARTBEAT_INTERVAL": "20",
                    "LOG_LEVEL": "WARNING",
                }
            )
            process = subprocess.Popen(
                [str(self.python), "-m", "scripts.src.handler"],
                cwd=self.root,
                env=environment,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            processes.append(process)
            logs.append(log)
        return processes, logs

    @staticmethod
    def _stop_workers(processes: list[subprocess.Popen[bytes]]) -> None:
        for process in processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
        deadline = time.monotonic() + 3
        for process in processes:
            if process.poll() is None:
                try:
                    process.wait(timeout=max(0.1, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()

    def _enqueue_jobs(self, queue_url: str, jobs: int) -> None:
        messages = []
        job_id = str(uuid.uuid4())
        requested_at = datetime.now(timezone.utc).isoformat()
        for index in range(jobs):
            payload = {
                "job_id": job_id,
                "source_folder": folder_label(index * 2),
                "destination_folder": folder_label(index * 2 + 1),
                "total_expected_pairs": jobs,
                "timestamp": requested_at,
                "user_id": "local-scaling-benchmark",
                "callback_id": "client-local",
            }
            messages.append(
                {
                    "Id": str(index),
                    "MessageBody": json.dumps(payload, separators=(",", ":")),
                }
            )
            if len(messages) == 10 or index == jobs - 1:
                response = self.sqs.send_message_batch(QueueUrl=queue_url, Entries=messages)
                if response.get("Failed"):
                    raise RuntimeError(f"failed to enqueue benchmark jobs: {response['Failed']}")
                messages = []

    def _wait_for_jobs(
        self,
        expected: int,
        timeout: int,
        processes: list[subprocess.Popen[bytes]],
        logs: list[object],
    ) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            failed_processes = [process for process in processes if process.poll() is not None]
            if failed_processes:
                raise RuntimeError(self._failure_message(processes, logs))
            with psycopg.connect(
                host=self.database.host,
                port=self.database.port,
                dbname=self.database.dbname,
                user=self.database.user,
                password=self.database.password,
            ) as connection:
                completed_jobs, completed_pairs, failed_pairs = connection.execute(
                    """
                    SELECT
                        (SELECT COUNT(*) FROM comparison_jobs WHERE status = 'completed'),
                        (SELECT COUNT(*) FROM comparison_results WHERE status = 'completed'),
                        (SELECT COUNT(*) FROM comparison_results WHERE status = 'failed')
                    """
                ).fetchone()
            if failed_pairs:
                raise RuntimeError(f"{failed_pairs} benchmark pair(s) failed")
            if completed_jobs == 1 and completed_pairs == expected:
                return
            time.sleep(0.2)
        raise TimeoutError(f"only some of {expected} jobs completed within {timeout} seconds")

    @staticmethod
    def _failure_message(
        processes: list[subprocess.Popen[bytes]], logs: list[object]
    ) -> str:
        details = []
        for index, (process, log) in enumerate(zip(processes, logs, strict=True)):
            if process.poll() is None:
                continue
            log.flush()
            path = Path(log.name)
            tail = path.read_text(encoding="utf-8", errors="replace")[-4000:]
            details.append(f"worker {index} exited {process.returncode}:\n{tail}")
        return "\n".join(details) or "a worker exited unexpectedly"


def print_results(results: list[TrialResult]) -> None:
    baseline = results[0].jobs_per_second
    print("\nworkers  seconds  jobs/sec  speedup  efficiency")
    for result in results:
        speedup = result.jobs_per_second / baseline
        efficiency = speedup / result.workers * 100
        print(
            f"{result.workers:>7}  {result.seconds:>7.2f}  "
            f"{result.jobs_per_second:>8.3f}  {speedup:>7.2f}x  {efficiency:>9.1f}%"
        )


def main() -> None:
    args = parse_args()
    worker_counts = [int(value) for value in args.workers.split(",")]
    if not worker_counts or any(value < 1 for value in worker_counts):
        raise ValueError("worker counts must be positive integers")
    if args.jobs < max(worker_counts) * 2:
        raise ValueError("jobs must be at least twice the largest worker count")
    if args.jobs > 100:
        raise ValueError("jobs cannot exceed the 100 generated folder pairs")

    benchmark = Benchmark(args)
    results: list[TrialResult] = []
    try:
        benchmark.setup()
        for worker_count in worker_counts:
            print(f"Running {args.jobs} jobs with {worker_count} worker(s)...", flush=True)
            result = benchmark.trial(worker_count, args.jobs, args.timeout)
            results.append(result)
            print(
                f"Completed in {result.seconds:.2f}s "
                f"({result.jobs_per_second:.3f} jobs/s)",
                flush=True,
            )
    finally:
        benchmark.cleanup()

    print_results(results)


if __name__ == "__main__":
    main()
