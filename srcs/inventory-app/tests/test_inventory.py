import unittest
from app import create_app
from app.extensions import db

class TestInventoryApp(unittest.TestCase):
    def setUp(self):
        self.app = create_app("sqlite:///:memory:")
        self.app.config["TESTING"] = True
        self.client = self.app.test_client()
        with self.app.app_context():
            db.create_all()

    def tearDown(self):
        with self.app.app_context():
            db.drop_all()

    def test_health_check(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json(), {"status": "healthy"})

    def test_create_and_get_movie(self):
        post_res = self.client.post("/api/movies", json={
            "title": "Interstellar",
            "description": "Christopher Nolan space epic"
        })
        self.assertEqual(post_res.status_code, 200)
        movie = post_res.get_json()
        self.assertIsNotNone(movie["id"])
        self.assertEqual(movie["title"], "Interstellar")
        movie_id = movie["id"]

        get_res = self.client.get(f"/api/movies/{movie_id}")
        self.assertEqual(get_res.status_code, 200)
        self.assertEqual(get_res.get_json()["title"], "Interstellar")

        list_res = self.client.get("/api/movies")
        self.assertEqual(list_res.status_code, 200)
        movies = list_res.get_json()["movies"]
        self.assertEqual(len(movies), 1)

    def test_filter_movies_by_title(self):
        self.client.post("/api/movies", json={"title": "The Matrix", "description": "Sci-fi classic"})
        self.client.post("/api/movies", json={"title": "Inception", "description": "Dream within dream"})

        res = self.client.get("/api/movies?title=Matrix")
        self.assertEqual(res.status_code, 200)
        data = res.get_json()["movies"]
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["title"], "The Matrix")

    def test_update_movie(self):
        create_res = self.client.post("/api/movies", json={"title": "Avatar", "description": "Pandora"})
        movie_id = create_res.get_json()["id"]

        update_res = self.client.put(f"/api/movies/{movie_id}", json={
            "title": "Avatar: The Way of Water",
            "description": "Ocean of Pandora"
        })
        self.assertEqual(update_res.status_code, 200)
        updated = update_res.get_json()
        self.assertEqual(updated["title"], "Avatar: The Way of Water")

    def test_delete_movie(self):
        create_res = self.client.post("/api/movies", json={"title": "Gladiator", "description": "Rome"})
        movie_id = create_res.get_json()["id"]

        del_res = self.client.delete(f"/api/movies/{movie_id}")
        self.assertEqual(del_res.status_code, 200)

        check_res = self.client.get(f"/api/movies/{movie_id}")
        self.assertEqual(check_res.status_code, 404)

    def test_create_movie_missing_title(self):
        res = self.client.post("/api/movies", json={"description": "No title here"})
        self.assertEqual(res.status_code, 400)
        self.assertIn("error", res.get_json())

if __name__ == "__main__":
    unittest.main()
