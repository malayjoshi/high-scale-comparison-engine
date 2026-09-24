import json
import unittest

from handler import deliver_callback


MESSAGE = {
    "event_id": "30a3e7d2-f886-47b6-b9d6-11c54d37fc4d",
    "event_type": "Comparison Job Completed",
    "detail": {
        "job_id": "job-1",
        "callback_id": "client-local",
        "status": "completed",
    },
}


class FakeTable:
    def __init__(self, item):
        self.item = item

    def get_item(self, **_kwargs):
        return {"Item": self.item} if self.item else {}


class FakeResponse:
    status = 202

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        pass


class FakeOpener:
    def open(self, request, timeout):
        self.request = request
        self.timeout = timeout
        return FakeResponse()


class CallbackTest(unittest.TestCase):
    def test_posts_to_registered_callback(self):
        opener = FakeOpener()
        deliver_callback(
            MESSAGE,
            FakeTable(
                {
                    "callback_url": "http://host.docker.internal:8080/jobs/completed",
                    "enabled": True,
                }
            ),
            opener,
        )

        self.assertEqual(opener.request.method, "POST")
        self.assertEqual(json.loads(opener.request.data), MESSAGE)
        self.assertEqual(
            opener.request.headers["X-comparison-event-id"], MESSAGE["event_id"]
        )

    def test_rejects_unregistered_callback(self):
        with self.assertRaisesRegex(ValueError, "not enabled"):
            deliver_callback(MESSAGE, FakeTable(None), FakeOpener())

    def test_rejects_nonlocal_http_callback(self):
        with self.assertRaisesRegex(ValueError, "must use HTTPS"):
            deliver_callback(
                MESSAGE,
                FakeTable({"callback_url": "http://example.com/callback", "enabled": True}),
                FakeOpener(),
            )


if __name__ == "__main__":
    unittest.main()
