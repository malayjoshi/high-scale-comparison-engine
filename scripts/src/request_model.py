"""Validate the flattened job contract at the worker trust boundary."""

from __future__ import annotations

import json
import re
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
    """One independently retryable folder pair within a client-generated job."""
    job_id: str
    pair: FolderPair
    expected_pair_count: int
    requested_at: datetime
    user_id: str
    callback_id: str

    @classmethod
    def from_message(cls, body: str) -> "ComparisonJob":
        """Parse an SQS message and reject malformed identity or pair metadata."""
        try:
            payload: dict[str, Any] = json.loads(body)
            job_id = str(uuid.UUID(payload["job_id"]))
            requested_at = datetime.fromisoformat(payload["timestamp"].replace("Z", "+00:00"))
            user_id = payload["user_id"].strip()
            callback_id = payload["callback_id"].strip()
            pair = FolderPair(
                source_folder=payload["source_folder"].strip(),
                destination_folder=payload["destination_folder"].strip(),
            )
            expected_pair_count = payload["total_expected_pairs"]
        except (AttributeError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ValueError(f"invalid comparison job: {exc}") from exc

        if requested_at.tzinfo is None:
            raise ValueError("invalid comparison job: timestamp must include a timezone")
        if not user_id:
            raise ValueError("invalid comparison job: user_id is required")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", callback_id):
            raise ValueError("invalid comparison job: callback_id is invalid")
        if not pair.source_folder or not pair.destination_folder:
            raise ValueError("invalid comparison job: folder names cannot be empty")
        if isinstance(expected_pair_count, bool) or not isinstance(expected_pair_count, int):
            raise ValueError("invalid comparison job: total_expected_pairs must be an integer")
        if not 1 <= expected_pair_count <= 100:
            raise ValueError("invalid comparison job: total_expected_pairs must be between 1 and 100")

        return cls(job_id, pair, expected_pair_count, requested_at, user_id, callback_id)
