"""Regression tests for live trace normalization. Run: python3 -I e2e/test_compare.py."""
import copy
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import DifySF, compare_traces
from e2ehttp import HTTPError


def trace(node_type, inputs):
    return {"events": [{"event": "node_finished", "exec": "node#1", "node_id": "node",
                        "node_type": node_type, "status": "succeeded", "inputs": inputs}], "edges": []}


class SelectionNormalizationTest(unittest.TestCase):
    def test_assigner_v2_editor_selection_is_ignored_without_mutating_saved_trace(self):
        inputs = {"type": "assigner", "version": "2", "selected": False, "items": []}
        a = trace("assigner", inputs)
        before = copy.deepcopy(a)
        b = trace("assigner", {k: v for k, v in inputs.items() if k != "selected"})
        self.assertEqual(compare_traces(a, b), [])
        self.assertEqual(a, before)

    def test_user_input_named_selected_is_compared_on_other_nodes(self):
        for node_type in ("start", "llm", "code"):
            with self.subTest(node_type=node_type):
                diffs = compare_traces(trace(node_type, {"selected": False}), trace(node_type, {}))
                self.assertTrue(any(d["path"].endswith(".inputs.selected") for d in diffs))

    def test_nested_assigner_values_and_older_versions_are_compared(self):
        for version in ("1", "2"):
            with self.subTest(version=version):
                a = trace("assigner", {"type": "assigner", "version": version, "selected": False,
                                      "items": [{"value": {"selected": False}}]})
                b = trace("assigner", {"type": "assigner", "version": version,
                                      "items": [{"value": {"selected": True}}]})
                diffs = compare_traces(a, b)
                self.assertTrue(any("items" in d["path"] for d in diffs))
                self.assertEqual(any(d["path"].endswith(".inputs.selected") for d in diffs), version == "1")


class RequestErrorComparisonTest(unittest.TestCase):
    def test_different_pre_execution_errors_are_not_equivalent(self):
        a = {"events": [{"event": "error", "code": "invalid_param", "status": 400, "message": "missing topic"}]}
        b = copy.deepcopy(a)
        self.assertEqual(compare_traces(a, b), [])
        b["events"][0]["message"] = "missing list"
        self.assertTrue(compare_traces(a, b))
        self.assertTrue(compare_traces(a, {"events": []}))


class ContainerRequestErrorTest(unittest.TestCase):
    def rejected(self, status, body):
        class RejectedSession:
            def stream(self, *args, **kwargs):
                raise HTTPError(status, body, "http://example.test/run")
        sf = object.__new__(DifySF)
        sf.s = RejectedSession()
        return sf.run_container("app", "iteration", "inner", {})

    def test_documented_http_validation_error_is_preserved_as_semantic_sse_error(self):
        events = list(self.rejected(400, '{"error":{"code":"invalid_param","message":"Invalid selector"}}'))
        self.assertEqual(events[0]["message"], "Invalid selector")
        self.assertEqual(events[0]["_http_status"], 400)
        self.assertEqual(events[0]["_http_body"]["error"]["code"], "invalid_param")

    def test_auth_server_and_malformed_errors_are_not_hidden(self):
        for status, body in [(403, '{"error":{"code":"forbidden"}}'), (500, '{}'), (400, 'not JSON')]:
            with self.subTest(status=status, body=body), self.assertRaises(HTTPError):
                list(self.rejected(status, body))


if __name__ == "__main__":
    unittest.main()
