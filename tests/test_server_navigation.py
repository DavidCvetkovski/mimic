"""Opening the studio from the vault must not expose the local API."""
import unittest
from types import SimpleNamespace
from core.server import Handler


class StudioNavigation(unittest.TestCase):
    def dispatch(self, path, method="GET", mode="navigate", dest="document"):
        handler = object.__new__(Handler)
        handler.server = SimpleNamespace(server_address=("127.0.0.1", 8455))
        handler.command, handler.path = method, path
        handler.headers = {"Host": "127.0.0.1:8455", "Sec-Fetch-Site": "cross-site",
                           "Sec-Fetch-Mode": mode, "Sec-Fetch-Dest": dest}
        result = []
        handler.fail = lambda code, message: result.append(code)
        handler.dispatch(lambda: result.append(200))
        return result

    def test_vault_link_can_open_studio(self):
        self.assertEqual(self.dispatch("/"), [200])
        self.assertEqual(self.dispatch("/index.html?from=vault"), [200])

    def test_cross_site_api_assets_frames_and_mutations_stay_blocked(self):
        for path in ("/api/voices", "/api/health", "/assets/app.js"):
            self.assertEqual(self.dispatch(path), [403])
        self.assertEqual(self.dispatch("/", method="POST"), [403])
        self.assertEqual(self.dispatch("/", mode="cors", dest="empty"), [403])
        self.assertEqual(self.dispatch("/", dest="iframe"), [403])
