import json
import unittest

from scripts.src.outbox import OutboxDispatcher
from scripts.src.repo import OutboxEvent


class FakeRepository:
    def __init__(self) -> None:
        self.event = OutboxEvent(
            "30a3e7d2-f886-47b6-b9d6-11c54d37fc4d",
            "Comparison Job Completed",
            {"job_id": "job-1", "callback_id": "client-production"},
        )
        self.published = []
        self.failed = []

    def claim_outbox(self) -> list[OutboxEvent]:
        return [self.event]

    def mark_outbox_published(self, event_id: str) -> None:
        self.published.append(event_id)

    def mark_outbox_failed(self, event_id: str, error: str) -> None:
        self.failed.append((event_id, error))


class FakeSQS:
    def __init__(self, *, fail: bool = False) -> None:
        self.fail = fail
        self.entries = []

    def send_message_batch(
        self, *, QueueUrl: str, Entries: list[dict[str, str]]
    ) -> dict[str, object]:
        self.queue_url = QueueUrl
        self.entries.extend(Entries)
        if self.fail:
            return {
                "Successful": [],
                "Failed": [
                    {"Id": Entries[0]["Id"], "Code": "InternalError", "Message": "retry"}
                ],
            }
        return {"Successful": [{"Id": Entries[0]["Id"], "MessageId": "sqs-id"}], "Failed": []}


class OutboxDispatcherTest(unittest.TestCase):
    def test_publishes_and_marks_event(self) -> None:
        repository = FakeRepository()
        sqs = FakeSQS()
        dispatcher = OutboxDispatcher(repository, sqs, "completion-queue-url")

        self.assertEqual(dispatcher.dispatch_once(), 1)
        self.assertEqual(repository.published, [repository.event.event_id])
        self.assertEqual(repository.failed, [])
        self.assertEqual(sqs.queue_url, "completion-queue-url")
        message = json.loads(sqs.entries[0]["MessageBody"])
        self.assertEqual(message["event_id"], repository.event.event_id)
        self.assertEqual(message["detail"]["callback_id"], "client-production")

    def test_failed_publish_is_released_for_retry(self) -> None:
        repository = FakeRepository()
        dispatcher = OutboxDispatcher(repository, FakeSQS(fail=True), "completion-queue-url")

        with self.assertLogs("comparison-worker.outbox", level="ERROR"):
            self.assertEqual(dispatcher.dispatch_once(), 1)
        self.assertEqual(repository.published, [])
        self.assertEqual(repository.failed[0][0], repository.event.event_id)


if __name__ == "__main__":
    unittest.main()
