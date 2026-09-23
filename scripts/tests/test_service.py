import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from scripts.src.request_model import ComparisonJob
from scripts.src.service import ComparisonService


class ComparisonServiceTest(unittest.TestCase):
    def test_compares_folders_columns_primary_keys_and_cells(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "folder_a"
            destination = root / "folder_b"
            results = root / "results"
            source.mkdir()
            destination.mkdir()

            (source / "common.random").write_text(
                "id,name,amount,deleted_column\n"
                "1,Alice,10,old\n"
                "2,Bob,20,old\n",
                encoding="utf-8",
            )
            (destination / "common.random").write_text(
                "id,name,amount,added_column\n"
                "1,Alice,11,new\n"
                "3,Carol,30,new\n",
                encoding="utf-8",
            )
            (source / "deleted.random").write_text("id,value\n1,x\n", encoding="utf-8")
            (destination / "added.random").write_text("id,value\n1,x\n", encoding="utf-8")

            job = ComparisonJob.from_message(
                json.dumps(
                    {
                        "job_id": "30a3e7d2-f886-47b6-b9d6-11c54d37fc4d",
                        "folder": [
                            {"source_folder": "folder_a", "destination_folder": "folder_b"}
                        ],
                        "timestamp": "2026-09-23T12:30:00Z",
                        "user_id": "microsoft-user-id",
                    }
                )
            )
            service = ComparisonService(root, results, max_workers=4)
            result = service.compare(job)
            folder = result["folder_comparisons"][0]
            comparison = folder["file_comparisons"][0]

            self.assertEqual(folder["files"]["common"], ["common.random"])
            self.assertEqual(folder["files"]["added"], ["added.random"])
            self.assertEqual(folder["files"]["deleted"], ["deleted.random"])
            self.assertEqual(comparison["columns"]["matching"], ["id", "name", "amount"])
            self.assertEqual(comparison["columns"]["added"], ["added_column"])
            self.assertEqual(comparison["columns"]["deleted"], ["deleted_column"])
            self.assertEqual(comparison["rows"]["added_primary_keys"], ["3"])
            self.assertEqual(comparison["rows"]["deleted_primary_keys"], ["2"])
            self.assertEqual(
                comparison["rows"]["cell_mismatches"],
                [
                    {
                        "primary_key": "1",
                        "column": "amount",
                        "source_value": "10",
                        "destination_value": "11",
                    }
                ],
            )

            result_path = service.save(job.job_id, result)
            self.assertEqual(json.loads(result_path.read_text()), result)

    def test_rejects_folder_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            service = ComparisonService(root, root / "results", max_workers=1)
            job = ComparisonJob(
                "30a3e7d2-f886-47b6-b9d6-11c54d37fc4d",
                (),
                datetime.now(timezone.utc),
                "user",
            )
            with self.assertRaises(ValueError):
                service._folder("../outside")


if __name__ == "__main__":
    unittest.main()
