import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("gemini_usage", Path(__file__).parents[1] / "Integrations/gemini-apps-usage.py")
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


def response(buckets, rpc="jSf9Qc"):
    return ")]}'\n123\n" + json.dumps([["wrb.fr", rpc, json.dumps([None, buckets])]])


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.current = [5000, 0.23, 1, [[1791000000, 0]]]
        self.weekly = [50000, 0.46, 2, [[1791300000, 500000000]]]

    def test_periods_do_not_depend_on_bucket_order(self):
        parsed = usage.parse_usage(response([self.weekly, self.current]))
        self.assertEqual(parsed["current"]["usedPercent"], 23)
        self.assertEqual(parsed["weekly"]["usedPercent"], 46)
        self.assertEqual(parsed["weekly"]["resetsAtEpoch"], 1791300000.5)

    def test_zero_and_exhaustion_are_used_fraction(self):
        self.current[1], self.weekly[1] = 0, 1
        parsed = usage.parse_usage(response([self.current, self.weekly]))
        self.assertEqual(parsed["current"]["usedPercent"], 0)
        self.assertEqual(parsed["weekly"]["usedPercent"], 100)

    def test_incomplete_unknown_and_malformed_fail_closed(self):
        for raw in [response([self.current]), response([self.current, self.weekly], "otherRPC"),
                    response([]), "not JSON"]:
            with self.subTest(raw=raw), self.assertRaises(usage.ProbeError):
                usage.parse_usage(raw)
        for invalid in [None, True, "0.23", -1, 2]:
            self.current[1] = invalid
            with self.subTest(fraction=invalid), self.assertRaises(usage.ProbeError):
                usage.parse_usage(response([self.current, self.weekly]))

    def test_duplicate_and_rejection_override_valid_payload(self):
        with self.assertRaises(usage.ProbeError):
            usage.parse_usage(response([self.current, self.current, self.weekly]))
        rejected = json.dumps([["wrb.fr", "jSf9Qc", None, None, None, [7]]])
        with self.assertRaisesRegex(usage.ProbeError, "session-rejected"):
            usage.parse_usage(response([self.current, self.weekly]) + "\n" + rejected)

    def test_bootstrap_json_escapes(self):
        self.assertEqual(usage.extract_token(r'{"SNlM0e":"a\u003db"}', "SNlM0e"), "a=b")

    def test_different_google_account_stops_before_quota_request(self):
        class Page:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self, limit): return b'{"oPEP7c":"other@example.invalid","SNlM0e":"synthetic"}'
        class Opener:
            requests = []
            def open(self, request, timeout):
                self.requests.append(request)
                return Page()
        opener = Opener()
        with patch.object(usage, "configuration", return_value=(Path("/unused"), "Default", "a" * 64)), \
             patch.object(usage, "browser_session", return_value="__Secure-1PSID=synthetic"), \
             patch.object(usage.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(usage.ProbeError, "account-mismatch"):
                usage.probe()
        self.assertEqual(len(opener.requests), 1)
        self.assertEqual(opener.requests[0].full_url, "https://gemini.google.com/usage")


if __name__ == "__main__":
    unittest.main()
