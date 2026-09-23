from __future__ import annotations

import json
import logging
import threading
from typing import Any

from .repo import JobRepository, OutboxEvent


LOG = logging.getLogger("comparison-worker.outbox")


class OutboxDispatcher:
    def __init__(
        self,
        repository: JobRepository,
        eventbridge: Any,
        event_bus_name: str,
        poll_interval: float = 2,
    ) -> None:
        self.repository = repository
        self.eventbridge = eventbridge
        self.event_bus_name = event_bus_name
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
        for event in events:
            self._publish(event)
        return len(events)

    def _run(self) -> None:
        while not self.stop_event.is_set():
            try:
                if self.dispatch_once() == 0:
                    self.stop_event.wait(self.poll_interval)
            except Exception:
                LOG.exception("outbox polling failed")
                self.stop_event.wait(self.poll_interval)

    def _publish(self, event: OutboxEvent) -> None:
        try:
            response = self.eventbridge.put_events(
                Entries=[
                    {
                        "EventBusName": self.event_bus_name,
                        "Source": "comparison-engine.worker",
                        "DetailType": event.event_type,
                        "Detail": json.dumps(event.payload, separators=(",", ":")),
                    }
                ]
            )
            entry = response.get("Entries", [{}])[0]
            if response.get("FailedEntryCount", 0) or entry.get("ErrorCode"):
                raise RuntimeError(
                    f"EventBridge rejected event: {entry.get('ErrorCode', 'unknown')} "
                    f"{entry.get('ErrorMessage', '')}".strip()
                )
            self.repository.mark_outbox_published(event.event_id)
        except Exception as exc:
            self.repository.mark_outbox_failed(event.event_id, str(exc))
            LOG.exception("failed to publish outbox event %s", event.event_id)
