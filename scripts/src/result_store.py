"""Write immutable, partition-friendly comparison documents to S3."""

from __future__ import annotations

import json
from datetime import datetime
from typing import Any
from urllib.parse import quote

from .request_model import ComparisonJob


class S3ResultStore:
    """Persist one folder-pair result and return its durable S3 location."""
    def __init__(self, s3: Any, bucket: str) -> None:
        self.s3 = s3
        self.bucket = bucket

    def put_folder_result(
        self,
        job: ComparisonJob,
        result: dict[str, Any],
        completed_at: datetime,
    ) -> str:
        source = quote(result["source_folder"], safe="")
        destination = quote(result["destination_folder"], safe="")
        key = (
            f"comparison-results/completion_date={completed_at.date().isoformat()}/"
            f"job_id={job.job_id}/{source}__{destination}.json"
        )
        document = {
            "job_id": job.job_id,
            "user_id": job.user_id,
            "request_timestamp": job.requested_at.isoformat(),
            "comparison_completed_at": completed_at.isoformat(),
            **result,
        }
        self.s3.put_object(
            Bucket=self.bucket,
            Key=key,
            Body=(json.dumps(document, separators=(",", ":")) + "\n").encode(),
            ContentType="application/json",
            ServerSideEncryption="AES256",
        )
        return f"s3://{self.bucket}/{key}"
