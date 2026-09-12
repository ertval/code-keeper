import unittest
import json
from app import create_app
from app.orders import Order

class TestBillingApp(unittest.TestCase):
    def setUp(self):
        self.app, self.session_factory = create_app("sqlite:///:memory:")
        self.app.config["TESTING"] = True
        self.client = self.app.test_client()

    def test_health_check(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json(), {"status": "healthy"})

    def test_order_model_and_listing(self):
        session = self.session_factory()
        try:
            order = Order(
                user_id="user-101",
                number_of_items=4,
                total_amount=120.50
            )
            session.add(order)
            session.commit()
            order_id = order.id
            self.assertIsNotNone(order_id)
        finally:
            session.close()

        res = self.client.get("/api/billing/orders")
        self.assertEqual(res.status_code, 200)
        data = res.get_json()
        self.assertEqual(len(data["orders"]), 1)
        self.assertEqual(data["orders"][0]["user_id"], "user-101")
        self.assertEqual(data["orders"][0]["number_of_items"], 4)
        self.assertEqual(data["orders"][0]["total_amount"], 120.50)

    def test_order_to_dict(self):
        order = Order(user_id="user-202", number_of_items=2, total_amount=45.0)
        d = order.to_dict()
        self.assertEqual(d["user_id"], "user-202")
        self.assertEqual(d["number_of_items"], 2)
        self.assertEqual(d["total_amount"], 45.0)

    def test_payload_validation_logic(self):
        raw_json = '{"user_id": "3", "number_of_items": "5", "total_amount": "180"}'
        data = json.loads(raw_json)
        user_id = str(data.get("user_id", "")).strip()
        number_of_items = int(data.get("number_of_items", 0))
        total_amount = float(data.get("total_amount", 0.0))

        self.assertEqual(user_id, "3")
        self.assertEqual(number_of_items, 5)
        self.assertEqual(total_amount, 180.0)

if __name__ == "__main__":
    unittest.main()
