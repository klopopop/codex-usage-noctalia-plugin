#!/usr/bin/env python3
"""Read Codex quotas using its app-server; never read or print auth material."""
import argparse
import fcntl
from pathlib import Path
import uuid
import json
import math
import os
import selectors
import shutil
import subprocess
import time


class UsageError(Exception):
    pass


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def window(raw):
    if not isinstance(raw, dict) or not number(raw.get('usedPercent')):
        return None
    return {
        'usedPercent': max(0, min(100, raw['usedPercent'])),
        'durationMins': raw.get('windowDurationMins') if number(raw.get('windowDurationMins')) else None,
        'resetsAt': raw.get('resetsAt') if number(raw.get('resetsAt')) else None,
    }


def normalize(result):
    if not isinstance(result, dict) or not isinstance(result.get('rateLimits'), dict):
        raise UsageError('protocol')
    buckets = result.get('rateLimitsByLimitId')
    if not isinstance(buckets, dict) or not buckets:
        buckets = {'codex': result['rateLimits']}
    limits = []
    for key in sorted(buckets, key=lambda k: (k != 'codex', k)):
        raw = buckets[key]
        if not isinstance(raw, dict):
            continue
        credits = raw.get('credits')
        limits.append({
            'id': str(key), 'name': raw.get('limitName') or str(key),
            'plan': raw.get('planType'),
            'primary': window(raw.get('primary')), 'secondary': window(raw.get('secondary')),
            'unlimitedCredits': isinstance(credits, dict) and credits.get('unlimited') is True,
            'creditBalance': credits.get('balance') if isinstance(credits, dict) else None,
            'reachedType': raw.get('rateLimitReachedType'),
        })
    if not limits:
        raise UsageError('protocol')
    reset = result.get('rateLimitResetCredits')
    available = reset.get('availableCount') if isinstance(reset, dict) else None
    return {'ok': True, 'fetchedAt': int(time.time()), 'limits': limits,
            'resetCredits': available if number(available) else None,
            'ordinaryUsageAllowed': result.get('ordinaryUsageAllowed')}


def fetch(binary, timeout=25, reset_key=None):
    # The reader consumes bytes rather than buffered readline: multiple replies in one
    # pipe write must not leave a complete line hidden behind select().
    try:
        process = subprocess.Popen([binary, 'app-server', '--stdio'], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
    except OSError:
        raise UsageError('missing_codex') from None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffer = bytearray()
    deadline = time.monotonic() + timeout

    def send(message):
        try:
            process.stdin.write((json.dumps(message) + '\n').encode())
            process.stdin.flush()
        except (OSError, ValueError):
            raise UsageError('unavailable') from None

    def receive(request_id):
        nonlocal buffer
        while True:
            while b'\n' in buffer:
                line, _, rest = buffer.partition(b'\n')
                buffer = bytearray(rest)
                try:
                    message = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    continue
                if not isinstance(message, dict):
                    continue
                if message.get('id') != request_id:
                    # No threads or turns are created. Do not approve server requests.
                    if 'id' in message and 'method' in message:
                        send({'id': message['id'], 'error': {'code': -32601, 'message': 'Read-only client'}})
                    continue
                if 'error' in message:
                    error = message['error']
                    text = str(error.get('message', '')).lower() if isinstance(error, dict) else ''
                    if any(word in text for word in ('login', 'sign in', 'not authenticated', 'unauthorized', '401', 'chatgpt authentication')):
                        raise UsageError('login_required')
                    raise UsageError('unavailable')
                return message.get('result')
            left = deadline - time.monotonic()
            if left <= 0 or not selector.select(left):
                raise UsageError('timeout')
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                raise UsageError('unavailable')
            buffer.extend(chunk)
            if len(buffer) > 4 * 1024 * 1024:
                raise UsageError('protocol')

    try:
        send({'id': 1, 'method': 'initialize', 'params': {
            'clientInfo': {'name': 'noctalia_codex_usage', 'title': 'Noctalia Codex Usage', 'version': '1.3.0'},
            'capabilities': {'experimentalApi': reset_key is not None}}})
        receive(1)
        send({'method': 'initialized', 'params': {}})
        if reset_key is None:
            send({'id': 2, 'method': 'account/rateLimits/read', 'params': {}})
            return normalize(receive(2))
        send({'id': 2, 'method': 'account/rateLimitResetCredit/consume',
              'params': {'idempotencyKey': reset_key}})
        result = receive(2)
        if not isinstance(result, dict) or result.get('outcome') not in {
                'reset', 'alreadyRedeemed', 'nothingToReset', 'noCredit'}:
            raise UsageError('protocol')
        return {'ok': True, 'outcome': result['outcome']}
    finally:
        selector.close()
        process.stdin.close()
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdout.close()


def reset(binary, state_dir=None):
    # Unknown results MUST reuse the same operation key after a timeout/restart.
    directory = Path(state_dir) if state_dir is not None else Path(
        os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'noctalia-codex-usage'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(directory / 'reset-attempt.json', os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(fd, 'r+') as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        text = file.read().strip()
        if text:
            try:
                key = str(uuid.UUID(json.loads(text)['idempotencyKey']))
            except (ValueError, KeyError, TypeError):
                # Do not replace an unreadable pending attempt with a fresh charge.
                raise UsageError('pending_reset') from None
        else:
            key = str(uuid.uuid4())
            file.seek(0)
            file.write(json.dumps({'idempotencyKey': key}))
            file.truncate()
            file.flush()
            os.fsync(file.fileno())
        result = fetch(binary, reset_key=key)
        # Clear only after an unambiguous backend result. No automatic retries.
        file.seek(0)
        file.truncate()
        file.flush()
        os.fsync(file.fileno())
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--reset', action='store_true', help='Consume one reset credit; only after user confirmation')
    args = parser.parse_args()
    binary = shutil.which(os.path.expanduser(args.codex))
    try:
        if binary is None:
            raise UsageError('missing_codex')
        result = reset(binary) if args.reset else fetch(binary)
    except UsageError as error:
        result = {'ok': False, 'error': str(error), 'checkedAt': int(time.time())}
    except Exception:
        # Never leak backend responses, account data, environment or tokens to logs.
        result = {'ok': False, 'error': 'unavailable', 'checkedAt': int(time.time())}
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))


if __name__ == '__main__':
    main()
