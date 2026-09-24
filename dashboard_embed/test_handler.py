import json
import unittest

from handler import create_embed_response


ENVIRONMENT = {
    "AWS_ACCOUNT_ID": "123456789012",
    "DASHBOARD_APP_ORIGIN": "http://localhost:3000",
    "QUICKSIGHT_ALLOWED_DOMAINS": '["http://localhost:3000"]',
    "QUICKSIGHT_DASHBOARD_ID": "comparison-engine-dashboard",
    "QUICKSIGHT_READERS": '{"reader@example.com":"arn:aws:quicksight:eu-west-1:123456789012:user/default/reader"}',
}


class FakeQuickSight:
    def generate_embed_url_for_registered_user(self, **kwargs):
        self.request = kwargs
        return {"EmbedUrl": "https://quicksight.example/embed/token"}


class DashboardEmbedTest(unittest.TestCase):
    def test_generates_link_for_registered_reader(self):
        quicksight = FakeQuickSight()
        response = create_embed_response(
            {
                "requestContext": {
                    "authorizer": {"claims": {"email": "Reader@Example.com"}}
                }
            },
            quicksight,
            ENVIRONMENT,
        )

        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(
            json.loads(response["body"])["embed_url"],
            "https://quicksight.example/embed/token",
        )
        self.assertEqual(quicksight.request["SessionLifetimeInMinutes"], 60)

    def test_rejects_unregistered_reader(self):
        response = create_embed_response(
            {"requestContext": {"authorizer": {"claims": {"email": "other@example.com"}}}},
            FakeQuickSight(),
            ENVIRONMENT,
        )

        self.assertEqual(response["statusCode"], 403)


if __name__ == "__main__":
    unittest.main()
