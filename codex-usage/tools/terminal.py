#!/usr/bin/env python3
"""Show one persistent Kitty/Codex window; Escape hides its special workspace."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

CLASS = 'codex-dropterm'
WORKSPACE = 'special:codex'


class TerminalError(Exception):
    pass


def hypr(*args, as_json=False):
    try:
        result = subprocess.run(['hyprctl', *args], capture_output=True, text=True, timeout=5, check=True)
        return json.loads(result.stdout) if as_json else result.stdout
    except (OSError, ValueError, subprocess.SubprocessError):
        raise TerminalError('Не удалось подключиться к Hyprland.') from None


def window():
    return next((c for c in hypr('-j', 'clients', as_json=True) if c.get('class') == CLASS), None)


def visible_monitor():
    return next((m for m in hypr('-j', 'monitors', as_json=True)
                 if m.get('specialWorkspace', {}).get('name') == WORKSPACE), None)


def hide():
    # Never toggle an unrelated workspace or inadvertently show a hidden terminal.
    monitor = visible_monitor()
    if monitor is None:
        return
    active = hypr('-j', 'activewindow', as_json=True)
    if active.get('class') != CLASS:
        return
    hypr('dispatch', 'hl.dsp.workspace.toggle_special("codex")')


def show(codex, directory):
    binary = shutil.which(os.path.expanduser(codex))
    if binary is None:
        raise TerminalError('Codex CLI не найден. Укажи путь к нему в настройках.')
    if shutil.which('kitty') is None:
        raise TerminalError('Для выпадающего терминала нужен Kitty.')
    directory = Path(directory).expanduser().resolve()
    if not directory.is_dir():
        raise TerminalError('Рабочая папка Codex не существует.')
    runtime = Path(os.environ.get('XDG_RUNTIME_DIR', f'/tmp/noctalia-codex-{os.getuid()}'))
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Serialize clicks through window creation: two clicks must not start two Codex sessions.
    with (runtime / 'noctalia-codex-terminal.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        client = window()
        if client is None:
            helper = str(Path(__file__).resolve())
            escape = 'map=escape launch --type=background ' + shlex.join([sys.executable, helper, 'hide'])
            # Kitty owns Escape for this window: it never reaches the Codex PTY.
            # ctrl+shift+Escape sends a literal Escape when the application needs it.
            with open(os.devnull, 'wb') as output:
                child = subprocess.Popen([
                    'kitty', '--class', CLASS, '--title', 'Codex · Esc — скрыть',
                    '--directory', str(directory), '--session', 'none',
                    '--override', escape,
                    '--override', 'map=ctrl+shift+escape send_text all \\x1b',
                    '--override', 'confirm_os_window_close=1',
                    binary,
                ], stdin=subprocess.DEVNULL, stdout=output, stderr=output, start_new_session=True)
            for _ in range(60):
                client = window()
                if client is not None:
                    break
                if child.poll() is not None:
                    raise TerminalError('Kitty завершился до создания окна.')
                time.sleep(0.1)
            if client is None:
                raise TerminalError('Окно Codex не появилось вовремя.')
        # The persistent rule should put the new window here. Also repair an
        # existing window accidentally moved to another workspace by the user.
        address = str(client.get('address', ''))
        if not address.startswith('0x') or any(c not in '0123456789abcdefABCDEF' for c in address[2:]):
            raise TerminalError('Некорректный адрес окна Hyprland.')
        if client.get('workspace', {}).get('name') != WORKSPACE:
            hypr('dispatch', 'hl.dsp.window.move({workspace="special:codex",follow=false,window="address:' + address + '"})')
        monitor = visible_monitor()
        if monitor is not None:
            hypr('dispatch', 'hl.dsp.focus({window="address:' + address + '"})')
        else:
            hypr('dispatch', 'hl.dsp.workspace.toggle_special("codex")')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['show', 'hide'])
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--directory', default='~')
    args = parser.parse_args()
    try:
        if args.action == 'hide':
            hide()
        else:
            show(args.codex, args.directory)
    except TerminalError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
