import json
import unittest
from datetime import datetime, timezone

from scripts.src.request_model import ComparisonJob, FolderPair
from scripts.src.result_store import S3ResultStore


class FakeS3:
    def __init__(self) -> None:
        self.request = None

    def put_object(self, **kwargs: object) -> None:
        self.request = kwargs


class ResultStoreTest(unittest.TestCase):
    def test_writes_partitioned_newline_delimited_json(self) -> None:
        s3 = FakeS3()
        store = S3ResultStore(s3, "results-bucket")
        job = ComparisonJob(
            "30a3e7d2-f886-47b6-b9d6-11c54d37fc4d",
            (FolderPair("folder_a", "folder_b"),),
            datetime(2026, 9, 23, 12, 0, tzinfo=timezone.utc),
            "microsoft-user-id",
        )
        completed_at = datetime(2026, 9, 23, 12, 5, tzinfo=timezone.utc)

        location = store.put_folder_result(
            job,
            {
                "source_folder": "folder_a",
                "destination_folder": "folder_b",
                "files": {"common": [], "added": [], "deleted": []},
                "file_comparisons": [],
            },
            completed_at,
        )

        expected_key = (
            "comparison-results/completion_date=2026-09-23/"
            "job_id=30a3e7d2-f886-47b6-b9d6-11c54d37fc4d/folder_a__folder_b.json"
        )
        self.assertEqual(s3.request["Key"], expected_key)
        self.assertEqual(location, f"s3://results-bucket/{expected_key}")
        self.assertTrue(s3.request["Body"].endswith(b"\n"))
        document = json.loads(s3.request["Body"])
        self.assertEqual(document["user_id"], "microsoft-user-id")
        self.assertEqual(document["comparison_completed_at"], completed_at.isoformat())
        self.assertEqual(s3.request["ServerSideEncryption"], "AES256")


if __name__ == "__main__":
    unittest.main()
