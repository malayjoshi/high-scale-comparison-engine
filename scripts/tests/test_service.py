import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from scripts.src.request_model import ComparisonJob, FolderPair
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
                        "source_folder": "folder_a",
                        "destination_folder": "folder_b",
                        "total_expected_pairs": 1,
                        "timestamp": "2026-09-23T12:30:00Z",
                        "user_id": "microsoft-user-id",
                        "callback_id": "client-production",
                    }
                )
            )
            service = ComparisonService(root, results, max_workers=4)
            result = service.compare(job)
            folder = result["folder_comparison"]
            comparison = folder["file_comparisons"][0]

            self.assertEqual(folder["files"]["common"], ["common.random"])
            self.assertEqual(folder["files"]["added"], ["added.random"])
            self.assertEqual(folder["files"]["deleted"], ["deleted.random"])
            self.assertFalse(comparison["identical"])
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

            result_path = service.save(job, result)
            self.assertEqual(json.loads(result_path.read_text()), result)

    def test_skips_csv_comparison_for_identical_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.random"
            destination = root / "destination.random"
            content = b"not,csv\n" + b"x" * (1024 * 1024)
            source.write_bytes(content)
            destination.write_bytes(content)

            result = ComparisonService._compare_file(source, destination)

            self.assertEqual(result, {"filename": "source.random", "identical": True})

    def test_rejects_folder_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            service = ComparisonService(root, root / "results", max_workers=1)
            job = ComparisonJob(
                "30a3e7d2-f886-47b6-b9d6-11c54d37fc4d",
                FolderPair("../outside", "folder_b"),
                1,
                datetime.now(timezone.utc),
                "user",
                "callback",
            )
            with self.assertRaises(ValueError):
                service._folder("../outside")


if __name__ == "__main__":
    unittest.main()
