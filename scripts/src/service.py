from __future__ import annotations

import csv
import json
import os
import tempfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .request_model import ComparisonJob, FolderPair


class ComparisonService:
    def __init__(self, data_root: Path, result_root: Path, max_workers: int) -> None:
        self.data_root = data_root.resolve()
        self.result_root = result_root
        self.max_workers = max(1, max_workers)

    def compare(self, job: ComparisonJob) -> dict[str, Any]:
        return self.build_result(job, self.compare_folders(job.pair))

    @staticmethod
    def build_result(
        job: ComparisonJob,
        folder_comparison: dict[str, Any],
    ) -> dict[str, Any]:
        return {
            "job_id": job.job_id,
            "user_id": job.user_id,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "folder_comparison": folder_comparison,
        }

    def save(self, job: ComparisonJob, result: dict[str, Any]) -> Path:
        self.result_root.mkdir(parents=True, exist_ok=True)
        result_name = f"{job.job_id}-{job.pair.source_folder}-{job.pair.destination_folder}"
        destination = self.result_root / f"{result_name}.json"
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=self.result_root,
            prefix=f".{result_name}-",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temp_path = Path(handle.name)
            json.dump(result, handle, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        temp_path.replace(destination)
        return destination

    def compare_folders(self, pair: FolderPair) -> dict[str, Any]:
        source = self._folder(pair.source_folder)
        destination = self._folder(pair.destination_folder)
        source_files = {path.name for path in source.glob("*.random") if path.is_file()}
        destination_files = {path.name for path in destination.glob("*.random") if path.is_file()}

        common = sorted(source_files & destination_files)
        added = sorted(destination_files - source_files)
        deleted = sorted(source_files - destination_files)

        def compare(filename: str) -> dict[str, Any]:
            return self._compare_file(source / filename, destination / filename)

        with ThreadPoolExecutor(max_workers=min(self.max_workers, max(1, len(common)))) as pool:
            comparisons = list(pool.map(compare, common))

        return {
            "source_folder": pair.source_folder,
            "destination_folder": pair.destination_folder,
            "files": {
                "common": common,
                "added": added,
                "deleted": deleted,
            },
            "file_comparisons": comparisons,
        }

    def _folder(self, name: str) -> Path:
        if not name or Path(name).name != name:
            raise ValueError(f"folder must be a direct child of the data root: {name!r}")
        path = (self.data_root / name).resolve()
        if path.parent != self.data_root or not path.is_dir():
            raise ValueError(f"folder does not exist under the data root: {name!r}")
        return path

    @staticmethod
    def _compare_file(source: Path, destination: Path) -> dict[str, Any]:
        source_columns, source_rows = _read_rows(source)
        destination_columns, destination_rows = _read_rows(destination)
        primary_key = source_columns[0]
        if destination_columns[0] != primary_key:
            raise ValueError(
                f"primary-key column differs for {source.name}: "
                f"{primary_key!r} != {destination_columns[0]!r}"
            )

        destination_column_set = set(destination_columns)
        source_column_set = set(source_columns)
        matching_columns = [column for column in source_columns if column in destination_column_set]
        added_columns = [column for column in destination_columns if column not in source_column_set]
        deleted_columns = [column for column in source_columns if column not in destination_column_set]

        source_keys = set(source_rows)
        destination_keys = set(destination_rows)
        matching_keys = sorted(source_keys & destination_keys)
        mismatches = []
        for key in matching_keys:
            for column in matching_columns[1:]:
                source_value = source_rows[key][column]
                destination_value = destination_rows[key][column]
                if source_value != destination_value:
                    mismatches.append(
                        {
                            "primary_key": key,
                            "column": column,
                            "source_value": source_value,
                            "destination_value": destination_value,
                        }
                    )

        return {
            "filename": source.name,
            "primary_key_column": primary_key,
            "columns": {
                "matching": matching_columns,
                "added": added_columns,
                "deleted": deleted_columns,
            },
            "rows": {
                "matching_primary_key_count": len(matching_keys),
                "added_primary_keys": sorted(destination_keys - source_keys),
                "deleted_primary_keys": sorted(source_keys - destination_keys),
                "cell_mismatches": mismatches,
            },
        }


def _read_rows(path: Path) -> tuple[list[str], dict[str, dict[str, str]]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle)
        try:
            columns = next(reader)
        except StopIteration as exc:
            raise ValueError(f"file is empty: {path}") from exc
        if not columns or not columns[0] or len(columns) != len(set(columns)):
            raise ValueError(f"file has an invalid header: {path}")

        rows: dict[str, dict[str, str]] = {}
        for line_number, values in enumerate(reader, start=2):
            if len(values) != len(columns):
                raise ValueError(f"wrong column count in {path} at line {line_number}")
            primary_key = values[0]
            if not primary_key or primary_key in rows:
                raise ValueError(f"missing or duplicate primary key in {path} at line {line_number}")
            rows[primary_key] = dict(zip(columns, values, strict=True))
    return columns, rows
