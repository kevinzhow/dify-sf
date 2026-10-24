"""The final pointer movement must not silently change the declared screenshot state."""
import unittest
from playwright.sync_api import sync_playwright
from capture_contract import prepare_final_state, assert_final_state, install_display_fixtures, FIXED_SECONDS
from compare import locate


class FinalStateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p = sync_playwright().start()
        cls.browser = cls.p.chromium.launch(headless=True, args=['--no-sandbox'])

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.p.stop()

    def setUp(self):
        self.page = self.browser.new_page(viewport={'width': 640, 'height': 480})
        self.page.set_content('''<style>#menu{position:absolute;left:100px;top:100px}</style>
            <div id="menu"><button>Light</button><button>Dark</button><button>System</button></div>
            <script>menu.addEventListener('mouseleave',()=>menu.hidden=true)</script>''')
        self.page.get_by_text('Light', exact=True).hover()
        self.case = {'expected': {'dify': {'text': 'Light', 'exact': True}},
                     'finalVisible': {'dify': [{'text': 'Dark', 'exact': True}]}}

    def tearDown(self):
        self.page.close()

    def test_old_park_outside_submenu_is_rejected(self):
        prepare_final_state(self.page, self.case, 'dify', locate)
        with self.assertRaisesRegex(AssertionError, 'disappeared'):
            assert_final_state(self.page, self.case, 'dify', locate)

    def test_explicit_pointer_preserves_submenu_before_and_after_capture(self):
        self.case['pointer'] = {'dify': {'text': 'Light', 'exact': True}}
        prepare_final_state(self.page, self.case, 'dify', locate)
        assert_final_state(self.page, self.case, 'dify', locate)
        self.assertGreater(len(self.page.screenshot()), 100)
        assert_final_state(self.page, self.case, 'dify', locate)

    def test_wrong_state_after_screenshot_is_rejected(self):
        assert_final_state(self.page, self.case, 'dify', locate)
        self.page.screenshot()
        self.page.locator('#menu').evaluate('(e)=>e.hidden=true')
        with self.assertRaisesRegex(AssertionError, 'disappeared'):
            assert_final_state(self.page, self.case, 'dify', locate)


    def test_display_fixture_changes_only_root_metadata_and_preserves_write_guard(self):
        import json, threading
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        writes = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                body = json.dumps({'timezone':'Asia/Tokyo', 'updated_at':17,
                                   'graph':{'updated_at':23}, 'outputs':{'created_at':31}, 'status':'succeeded'}).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(body)
            def do_POST(self):
                writes.append(self.path); self.send_response(204); self.end_headers()
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
        context = self.browser.new_context()
        context.route('**/*', lambda route: route.abort() if route.request.method != 'GET' else route.continue_())
        page = context.new_page(); install_display_fixtures(page, 'dify')
        base = f'http://127.0.0.1:{server.server_port}'
        try:
            page.goto(base)
            self.assertEqual(page.evaluate('Date.now()'), FIXED_SECONDS * 1000)
            profile = page.evaluate('(url)=>fetch(url).then(r=>r.json())', base+'/console/api/account/profile')
            self.assertEqual(profile['timezone'], 'America/New_York')
            self.assertEqual(profile['updated_at'], 17)
            draft = page.evaluate('(url)=>fetch(url).then(r=>r.json())', base+'/console/api/apps/fixture/workflows/draft')
            self.assertEqual(draft['updated_at'], FIXED_SECONDS)
            self.assertEqual(draft['graph'], {'updated_at':23})
            self.assertEqual(draft['outputs'], {'created_at':31})
            self.assertEqual(draft['status'], 'succeeded')
            page.evaluate('(url)=>fetch(url,{method:"POST"}).catch(()=>null)', base+'/console/api/account/profile')
            self.assertEqual(writes, [])
        finally:
            context.close(); server.shutdown(); server.server_close()


if __name__ == '__main__':
    unittest.main()
