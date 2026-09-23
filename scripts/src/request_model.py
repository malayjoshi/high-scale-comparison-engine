from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any


@dataclass(frozen=True)
class FolderPair:
    source_folder: str
    destination_folder: str


@dataclass(frozen=True)
class ComparisonJob:
    job_id: str
    folders: tuple[FolderPair, ...]
    requested_at: datetime
    user_id: str

    @classmethod
    def from_message(cls, body: str) -> "ComparisonJob":
        try:
            payload: dict[str, Any] = json.loads(body)
            job_id = str(uuid.UUID(payload["job_id"]))
            requested_at = datetime.fromisoformat(payload["timestamp"].replace("Z", "+00:00"))
            user_id = payload["user_id"].strip()
            folders = tuple(
                FolderPair(
                    source_folder=item["source_folder"].strip(),
                    destination_folder=item["destination_folder"].strip(),
                )
                for item in payload["folder"]
            )
        except (AttributeError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ValueError(f"invalid comparison job: {exc}") from exc

        if requested_at.tzinfo is None:
            raise ValueError("invalid comparison job: timestamp must include a timezone")
        if not user_id:
            raise ValueError("invalid comparison job: user_id is required")
        if not folders:
            raise ValueError("invalid comparison job: at least one folder pair is required")
        if len(folders) != len(set(folders)):
            raise ValueError("invalid comparison job: folder pairs must be unique")
        for pair in folders:
            if not pair.source_folder or not pair.destination_folder:
                raise ValueError("invalid comparison job: folder names cannot be empty")

        return cls(job_id, folders, requested_at, user_id)
