import unittest
import json
from unittest.mock import patch, MagicMock
from app import create_app

class TestApiGateway(unittest.TestCase):
    def setUp(self):
        self.app = create_app()
        self.app.config["TESTING"] = True
        self.client = self.app.test_client()

    def test_health_check(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertEqual(data["status"], "healthy")

    def test_swagger_ui_endpoint(self):
        response = self.client.get("/docs")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"SwaggerUIBundle", response.data)

    def test_openapi_spec_endpoint(self):
        response = self.client.get("/openapi.yaml")
        self.assertIn(response.status_code, [200, 404])

    def test_billing_missing_body(self):
        response = self.client.post("/api/billing", data="", content_type="application/json")
        self.assertEqual(response.status_code, 400)
        data = response.get_json()
        self.assertIn("error", data)

    @patch("app.proxy.sender.publish_message")
    def test_billing_valid_order(self, mock_publish):
        mock_publish.return_value = None
        order_data = {
            "user_id": "user-42",
            "number_of_items": 3,
            "total_amount": 99.50
        }
        response = self.client.post("/api/billing", json=order_data)
        self.assertEqual(response.status_code, 200)
        mock_publish.assert_called_once()
        data = response.get_json()
        self.assertIn("sent", data["message"])

    @patch("requests.request")
    def test_inventory_proxy_success(self, mock_request):
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.content = b'{"movies": []}'
        mock_resp.headers = {"Content-Type": "application/json"}
        mock_request.return_value = mock_resp

        response = self.client.get("/api/movies")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json(), {"movies": []})

if __name__ == "__main__":
    unittest.main()
