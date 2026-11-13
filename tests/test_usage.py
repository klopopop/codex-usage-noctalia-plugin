import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import textwrap
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('usage', ROOT / 'codex-usage/tools/usage.py')
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


class NormalizeTests(unittest.TestCase):
    def test_legacy_and_unknown_window(self):
        data = usage.normalize({'rateLimits': {'planType': 'plus', 'primary': {'usedPercent': 0}, 'secondary': None}})
        self.assertEqual(data['limits'][0]['primary']['usedPercent'], 0)
        self.assertIsNone(data['limits'][0]['primary']['resetsAt'])
        self.assertIsNone(data['limits'][0]['secondary'])
        self.assertIsNone(data['resetCredits'])

    def test_multiple_buckets_no_duplicate_legacy_and_no_account_data(self):
        data = usage.normalize({'accountId': 'private', 'rateLimits': {'primary': {'usedPercent': 20}},
            'rateLimitsByLimitId': {'other': {'primary': {'usedPercent': 200}},
                                  'codex': {'primary': {'usedPercent': 9}, 'credits': {'balance': '0', 'unlimited': False}}},
            'rateLimitResetCredits': {'availableCount': 3}, 'ordinaryUsageAllowed': False})
        self.assertEqual([b['id'] for b in data['limits']], ['codex', 'other'])
        self.assertEqual(data['limits'][1]['primary']['usedPercent'], 100)
        self.assertEqual(data['resetCredits'], 3)
        self.assertFalse(data['ordinaryUsageAllowed'])
        self.assertNotIn('private', json.dumps(data))

    def test_malformed_is_not_zero_usage(self):
        for value in [None, True, '20', float('nan')]:
            self.assertIsNone(usage.window({'usedPercent': value}))
        with self.assertRaises(usage.UsageError):
            usage.normalize({})


class ProtocolTests(unittest.TestCase):
    def fake(self, body):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / 'fake-codex'
        path.write_text('#!/usr/bin/env python3\n' + textwrap.dedent(body))
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return str(path)

    def test_handshake_notifications_and_only_read_methods(self):
        binary = self.fake('''
            import sys,json
            for line in sys.stdin:
                req=json.loads(line)
                method=req['method']
                if method=='initialize':
                    print(json.dumps({'method':'notification'})+'\\n'+json.dumps({'id':1,'result':{}}),flush=True)
                elif method=='initialized':
                    pass
                elif method=='account/rateLimits/read':
                    print(json.dumps({'method':'unrelated'})+'\\n'+json.dumps({'id':2,'result':{'rateLimits':{'primary':{'usedPercent':42}}}}),flush=True)
                else:
                    raise RuntimeError('Unexpected method')
        ''')
        self.assertEqual(usage.fetch(binary, 2)['limits'][0]['primary']['usedPercent'], 42)

    def test_auth_error_is_sanitized(self):
        binary = self.fake('''
            import sys,json
            for line in sys.stdin:
                req=json.loads(line)
                if req.get('id'):
                    print(json.dumps({'id':req['id'],'error':{'message':'Unauthorized 401 secret-token'}}),flush=True)
        ''')
        with self.assertRaisesRegex(usage.UsageError, '^login_required$'):
            usage.fetch(binary, 2)

    def test_timeout_terminates_child(self):
        binary = self.fake('''
            import time
            time.sleep(30)
        ''')
        with self.assertRaisesRegex(usage.UsageError, '^timeout$'):
            usage.fetch(binary, 0.1)

    def test_eof_is_handled(self):
        binary = self.fake('pass')
        with self.assertRaisesRegex(usage.UsageError, '^unavailable$'):
            usage.fetch(binary, 2)


class ResetTests(unittest.TestCase):
    def test_uncertain_result_reuses_key(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(usage, 'fetch', side_effect=usage.UsageError('timeout')) as first:
                with self.assertRaises(usage.UsageError): usage.reset('fake', directory)
                key = first.call_args.kwargs['reset_key']
            with patch.object(usage, 'fetch', return_value={'ok': True, 'outcome': 'alreadyRedeemed'}) as retry:
                self.assertEqual(usage.reset('fake', directory)['outcome'], 'alreadyRedeemed')
                self.assertEqual(retry.call_args.kwargs['reset_key'], key)
            self.assertEqual((Path(directory) / 'reset-attempt.json').read_text(), '')

    def test_confirmed_results_complete_attempt(self):
        for outcome in ['reset', 'noCredit', 'nothingToReset', 'alreadyRedeemed']:
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                with patch.object(usage, 'fetch', return_value={'ok': True, 'outcome': outcome}):
                    self.assertEqual(usage.reset('fake', directory)['outcome'], outcome)
                self.assertEqual((Path(directory) / 'reset-attempt.json').read_text(), '')

    def test_invalid_pending_attempt_does_not_charge(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'reset-attempt.json').write_text('broken')
            with patch.object(usage, 'fetch') as fetch:
                with self.assertRaisesRegex(usage.UsageError, 'pending_reset'):
                    usage.reset('fake', directory)
                fetch.assert_not_called()


class ResetProtocolTests(unittest.TestCase):
    fake = ProtocolTests.fake
    def test_explicit_reset_sends_one_mutation_with_idempotency_key(self):
        binary = self.fake('''
            import sys,json
            for line in sys.stdin:
                req=json.loads(line)
                if req['method']=='initialize':
                    assert req['params']['capabilities']['experimentalApi'] is True
                    print(json.dumps({'id':1,'result':{}}),flush=True)
                elif req['method']=='initialized': pass
                elif req['method']=='account/rateLimitResetCredit/consume':
                    assert req['params']=={'idempotencyKey':'test-stable-key'}
                    print(json.dumps({'id':2,'result':{'outcome':'reset'}}),flush=True)
                else: raise RuntimeError('Unexpected method')
        ''')
        self.assertEqual(usage.fetch(binary,2,reset_key='test-stable-key'), {'ok':True,'outcome':'reset'})


if __name__ == '__main__':
    unittest.main()
