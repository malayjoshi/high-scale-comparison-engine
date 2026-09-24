"""Publish committed completion events from PostgreSQL to the callback queue."""

from __future__ import annotations

import json
import logging
import threading
from typing import Any

from .repo import JobRepository, OutboxEvent


LOG = logging.getLogger("comparison-worker.outbox")


class OutboxDispatcher:
    """Poll the transactional outbox and retry failed SQS publications safely."""
    def __init__(
        self,
        repository: JobRepository,
        sqs: Any,
        queue_url: str,
        poll_interval: float = 2,
    ) -> None:
        self.repository = repository
        self.sqs = sqs
        self.queue_url = queue_url
        self.poll_interval = poll_interval
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, name="outbox-dispatcher", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join()

    def dispatch_once(self) -> int:
        events = self.repository.claim_outbox()
        if events:
            self._publish(events)
        return len(events)

    def _run(self) -> None:
        while not self.stop_event.is_set():
            try:
                if self.dispatch_once() == 0:
                    self.stop_event.wait(self.poll_interval)
            except Exception:
                LOG.exception("outbox polling failed")
                self.stop_event.wait(self.poll_interval)

    def _publish(self, events: list[OutboxEvent]) -> None:
        try:
            response = self.sqs.send_message_batch(
                QueueUrl=self.queue_url,
                Entries=[
                    {
                        "Id": event.event_id,
                        "MessageBody": json.dumps(
                            {
                                "event_id": event.event_id,
                                "event_type": event.event_type,
                                "detail": event.payload,
                            },
                            separators=(",", ":"),
                        ),
                    }
                    for event in events
                ],
            )
        except Exception as exc:
            for event in events:
                self.repository.mark_outbox_failed(event.event_id, str(exc))
            LOG.exception("failed to publish outbox batch")
            return

        successful_ids = {entry["Id"] for entry in response.get("Successful", [])}
        failures = {entry["Id"]: entry for entry in response.get("Failed", [])}
        for event in events:
            if event.event_id in successful_ids:
                self.repository.mark_outbox_published(event.event_id)
                continue

            failure = failures.get(event.event_id, {})
            error = (
                f"SQS rejected event: {failure.get('Code', 'unknown')} "
                f"{failure.get('Message', 'missing batch result')}"
            ).strip()
            self.repository.mark_outbox_failed(event.event_id, error)
            LOG.error("failed to publish outbox event %s: %s", event.event_id, error)
