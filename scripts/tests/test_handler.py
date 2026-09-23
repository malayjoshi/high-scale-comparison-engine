import json
import unittest
from pathlib import Path
from types import SimpleNamespace

from scripts.src.handler import Worker


MESSAGE = {
    "ReceiptHandle": "receipt",
    "Body": json.dumps(
        {
            "job_id": "30a3e7d2-f886-47b6-b9d6-11c54d37fc4d",
            "folder": [{"source_folder": "folder_a", "destination_folder": "folder_b"}],
            "timestamp": "2026-09-23T12:30:00Z",
            "user_id": "microsoft-user-id",
        }
    ),
}


class FakeSQS:
    def __init__(self) -> None:
        self.deleted = []
        self.visibility = []

    def delete_message(self, **kwargs: object) -> None:
        self.deleted.append(kwargs)

    def change_message_visibility(self, **kwargs: object) -> None:
        self.visibility.append(kwargs)


class FakeRepository:
    def __init__(self, claim: str = "claimed") -> None:
        self.claim_result = claim
        self.completed = []
        self.failed = []
        self.results = []

    def claim(self, _job: object) -> str:
        return self.claim_result

    def heartbeat(self, _job_id: str) -> None:
        pass

    def complete(self, job_id: str, path: str) -> None:
        self.completed.append((job_id, path))

    def record_result(self, *args: object) -> None:
        self.results.append(args)

    def fail(self, job_id: str, error: str) -> None:
        self.failed.append((job_id, error))


class FakeComparison:
    def __init__(self, error: Exception | None = None) -> None:
        self.error = error

    def compare_folders(self, pair: object) -> dict[str, object]:
        if self.error:
            raise self.error
        return {
            "source_folder": pair.source_folder,
            "destination_folder": pair.destination_folder,
            "result": "ok",
        }

    def build_result(self, _job: object, folders: object) -> dict[str, object]:
        return {"folder_comparisons": folders}

    def save(self, job_id: str, _result: object) -> Path:
        return Path(f"/var/tmp/comparison-engine/{job_id}.json")


class FakeResultStore:
    def __init__(self) -> None:
        self.uploads = []

    def put_folder_result(self, job: object, result: object, completed_at: object) -> str:
        self.uploads.append((job, result, completed_at))
        return f"s3://results/{job.job_id}.json"


class WorkerTest(unittest.TestCase):
    def worker(self, *, claim: str = "claimed", error: Exception | None = None) -> Worker:
        worker = object.__new__(Worker)
        worker.settings = SimpleNamespace(
            queue_url="queue-url",
            visibility_timeout=300,
            heartbeat_interval=60,
        )
        worker.sqs = FakeSQS()
        worker.repository = FakeRepository(claim)
        worker.comparison = FakeComparison(error)
        worker.result_store = FakeResultStore()
        return worker

    def test_completes_and_deletes_message(self) -> None:
        worker = self.worker()
        worker._handle(MESSAGE)
        self.assertEqual(len(worker.repository.completed), 1)
        self.assertEqual(len(worker.repository.results), 1)
        self.assertEqual(len(worker.result_store.uploads), 1)
        self.assertEqual(len(worker.sqs.deleted), 1)
        self.assertEqual(worker.sqs.visibility, [])

    def test_failure_marks_job_failed_and_releases_message(self) -> None:
        worker = self.worker(error=RuntimeError("comparison failed"))
        with self.assertLogs("comparison-worker", level="ERROR"):
            worker._handle(MESSAGE)
        self.assertEqual(worker.repository.failed[0][1], "comparison failed")
        self.assertEqual(worker.sqs.visibility[0]["VisibilityTimeout"], 0)
        self.assertEqual(worker.sqs.deleted, [])

    def test_completed_duplicate_is_only_deleted(self) -> None:
        worker = self.worker(claim="completed")
        worker._handle(MESSAGE)
        self.assertEqual(len(worker.sqs.deleted), 1)
        self.assertEqual(worker.repository.completed, [])


if __name__ == "__main__":
    unittest.main()
