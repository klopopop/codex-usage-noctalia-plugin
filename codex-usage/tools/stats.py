#!/usr/bin/env python3
"""Локальная статистика Codex по журналам ~/.codex/sessions/**/rollout-*.jsonl.

Читает только записи token_usage_record (токены), turn_context (модель, папка)
и session_meta (папка); текст переписки не трогает. Печатает одну строку JSON
в той же схеме, что и плагин Claude Usage: сегодня, неделя, 14 дней, тепловая
карта 7×24, модели, проекты.

Разбор инкрементальный: смещения и суммы по дням — в
~/.cache/noctalia-codex-usage/stats-index.json.
"""
import argparse
from datetime import date, datetime, timedelta
import json
import os
from pathlib import Path
import time

INDEX_VERSION = 1
KEEP_DAYS = 60
GENERIC = {'src', 'app', 'api', 'web', 'backend', 'frontend', 'client', 'server', 'source'}


def empty_day():
    return {'i': 0, 'o': 0, 'cr': 0, 'cw': 0, 'n': 0, 'h': [0] * 24, 'm': {}}


def num(value):
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def scan_file(path, entry, cutoff):
    size = path.stat().st_size
    if size < entry.get('offset', 0):
        entry.clear()
    entry.setdefault('offset', 0)
    entry.setdefault('days', {})
    entry.setdefault('seen', [])  # последние response_id — от повторов
    with path.open('rb') as file:
        file.seek(entry['offset'])
        while True:
            line = file.readline()
            if not line or not line.endswith(b'\n'):
                break  # недописанная строка — в следующий раз
            entry['offset'] += len(line)
            if b'"turn_context"' in line[:120] or b'"session_meta"' in line[:120]:
                try:
                    payload = json.loads(line).get('payload') or {}
                except ValueError:
                    continue
                if isinstance(payload.get('cwd'), str):
                    entry['project'] = payload['cwd']
                if isinstance(payload.get('model'), str):
                    entry['model'] = payload['model']
                continue
            if b'"token_usage_record"' not in line[:120]:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            payload = record.get('payload') or {}
            usage = payload.get('usage')
            if not isinstance(usage, dict):
                continue
            rid = payload.get('response_id')
            if rid is not None:
                if rid in entry['seen']:
                    continue
                entry['seen'] = (entry['seen'] + [rid])[-20:]
            try:
                when = datetime.fromisoformat(str(record.get('timestamp')).replace('Z', '+00:00')).astimezone()
            except ValueError:
                continue
            day_key = when.date().isoformat()
            if day_key < cutoff:
                continue
            day = entry['days'].setdefault(day_key, empty_day())
            cached = num(usage.get('cached_input_tokens'))
            fresh_in = max(0, num(usage.get('input_tokens')) - cached)
            out = num(usage.get('output_tokens'))
            cw = num(usage.get('cache_write_input_tokens'))
            day['i'] += fresh_in
            day['o'] += out
            day['cr'] += cached
            day['cw'] += cw
            day['n'] += 1
            day['h'][when.hour] += 1
            model = entry.get('model') or '?'
            day['m'][model] = day['m'].get(model, 0) + fresh_in + out + cw
    entry['size'] = size
    entry['mtime'] = path.stat().st_mtime


def short_project(path, home):
    if path == home:
        return '~'
    parts = [p for p in path.rstrip('/').split('/') if p]
    if not parts:
        return path
    if parts[-1].lower() in GENERIC and len(parts) > 1:
        return parts[-2] + '/' + parts[-1]
    return parts[-1]


def pretty_model(model):
    # gpt-6.1-sol → GPT 6.1 Sol
    parts = model.split('-')
    out = []
    for part in parts:
        out.append(part.upper() if part.lower() == 'gpt' else (part if part[:1].isdigit() else part.capitalize()))
    return ' '.join(out) or model


def build(root, cache):
    index_path = cache / 'stats-index.json'
    try:
        index = json.loads(index_path.read_text())
        if index.get('version') != INDEX_VERSION:
            index = {}
    except (OSError, ValueError):
        index = {}
    files = index.setdefault('files', {})
    index['version'] = INDEX_VERSION
    today = date.today()
    cutoff = (today - timedelta(days=KEEP_DAYS)).isoformat()

    seen = set()
    for path in root.glob('**/*.jsonl'):
        key = str(path)
        seen.add(key)
        try:
            stat = path.stat()
        except OSError:
            continue
        entry = files.setdefault(key, {})
        if entry.get('size') == stat.st_size and entry.get('mtime') == stat.st_mtime:
            continue
        try:
            scan_file(path, entry, cutoff)
        except OSError:
            continue
    for key in list(files):
        if key not in seen:
            del files[key]
        else:
            days = files[key].get('days', {})
            for day_key in [d for d in days if d < cutoff]:
                del days[day_key]

    cache.mkdir(parents=True, exist_ok=True)
    tmp = index_path.with_suffix('.tmp')
    tmp.write_text(json.dumps(index, separators=(',', ':')))
    os.replace(tmp, index_path)

    last14 = [(today - timedelta(days=k)).isoformat() for k in range(13, -1, -1)]
    last7 = set(last14[-7:])
    per_day = {d: empty_day() for d in last14}
    sessions = {d: set() for d in last14}
    models, projects = {}, {}
    home = str(Path.home())
    for key, entry in files.items():
        project = entry.get('project') or '?'
        for day_key, day in entry.get('days', {}).items():
            if day_key not in per_day:
                continue
            total = per_day[day_key]
            for field in ('i', 'o', 'cr', 'cw', 'n'):
                total[field] += day[field]
            for hour in range(24):
                total['h'][hour] += day['h'][hour]
            sessions[day_key].add(key)
            if day_key in last7:
                for model, tokens in day['m'].items():
                    models[model] = models.get(model, 0) + tokens
                proj = projects.setdefault(project, {'tokens': 0, 'n': 0, 'days': set()})
                proj['tokens'] += day['i'] + day['o'] + day['cw']
                proj['n'] += day['n']
                proj['days'].add(day_key)

    def summary(keys):
        out = {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0, 'messages': 0}
        sess = set()
        for d in keys:
            day = per_day[d]
            out['input'] += day['i']
            out['output'] += day['o']
            out['cacheRead'] += day['cr']
            out['cacheWrite'] += day['cw']
            out['messages'] += day['n']
            sess |= sessions[d]
        out['sessions'] = len(sess)
        out['fresh'] = out['input'] + out['output'] + out['cacheWrite']
        out['total'] = out['fresh'] + out['cacheRead']
        return out

    streak = 0
    for d in reversed(last14):
        if per_day[d]['n'] > 0:
            streak += 1
        elif d != today.isoformat():
            break
    total_models = sum(models.values()) or 1
    total_projects = sum(p['tokens'] for p in projects.values()) or 1
    return {
        'ok': True,
        'generatedAt': int(time.time()),
        'today': summary([today.isoformat()]),
        'week': summary(last14[-7:]),
        'prevWeek': summary(last14[:7]),
        'days': [{'date': d, 'weekday': date.fromisoformat(d).weekday(),
                  'fresh': per_day[d]['i'] + per_day[d]['o'] + per_day[d]['cw'],
                  'output': per_day[d]['o'], 'messages': per_day[d]['n'],
                  'sessions': len(sessions[d])} for d in last14],
        'heat': [per_day[d]['h'] for d in last14[-7:]],
        'models': [{'id': m, 'name': pretty_model(m), 'tokens': t, 'share': t / total_models}
                   for m, t in sorted(models.items(), key=lambda kv: -kv[1])][:6],
        'projects': [{'path': p.replace(home, '~', 1), 'name': short_project(p, home), 'tokens': v['tokens'],
                      'messages': v['n'], 'days': len(v['days']), 'share': v['tokens'] / total_projects}
                     for p, v in sorted(projects.items(), key=lambda kv: -kv[1]['tokens'])][:6],
        'streak': streak,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', default=os.path.join(os.environ.get('CODEX_HOME', '~/.codex'), 'sessions'))
    parser.add_argument('--cache', default=os.path.join(
        os.environ.get('XDG_CACHE_HOME', '~/.cache'), 'noctalia-codex-usage'))
    args = parser.parse_args()
    try:
        result = build(Path(args.root).expanduser(), Path(args.cache).expanduser())
    except Exception as error:  # noqa: BLE001
        result = {'ok': False, 'error': type(error).__name__, 'generatedAt': int(time.time())}
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))


if __name__ == '__main__':
    main()
