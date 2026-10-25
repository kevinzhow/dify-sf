#!/usr/bin/env python3
"""Native startup failure/cleanup regression. Uses no real account or server."""
import argparse
import json
import os
import pathlib
import secrets
import signal
import socket
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--cleanup-lock')
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = secrets.token_hex(32)
    for name, mode, value in [('valid.key', 0o600, key), ('weak.key', 0o600, 'weak'), ('public.key', 0o644, key)]:
        fd = os.open(output / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(fd, 'w') as stream:
            stream.write(value)
        os.chmod(output / name, mode)
    # Own the collision port; do not probe or interfere with another service.
    collision = socket.socket()
    collision.bind(('127.0.0.1', 0))
    collision.listen()
    busy = collision.getsockname()[1]
    cases = [
        ('missing-option', ['--mcp-port', str(busy)]),
        ('missing-file', ['--mcp-port', str(busy), '--mcp-token-file', str(output / 'absent.key')]),
        ('weak-key', ['--mcp-port', str(busy), '--mcp-token-file', str(output / 'weak.key')]),
        ('public-key', ['--mcp-port', str(busy), '--mcp-token-file', str(output / 'public.key')]),
        ('busy-port', ['--mcp-port', str(busy), '--mcp-token-file', str(output / 'valid.key')]),
        ('invalid-port', ['--mcp-port', 'invalid', '--mcp-token-file', str(output / 'valid.key')]),
    ]
    runtime = output / 'runtime'
    runtime.mkdir(mode=0o700)
    results = []
    try:
        for name, options in cases:
            case = output / name
            case.mkdir(mode=0o700)
            env = dict(os.environ, DIFYSF_CLIENT_BINARY=str(binary), DIFYSF_MCP_RUNTIME_ROOT=str(runtime),
                       XDG_CONFIG_HOME=str(case / 'config'), XDG_DATA_HOME=str(case / 'data'),
                       XDG_CACHE_HOME=str(case / 'cache'))
            if args.cleanup_lock:
                env['DIFYSF_CLEANUP_LOCK'] = args.cleanup_lock
            with (case / 'process.log').open('w') as log:
                result = subprocess.Popen([str(pathlib.Path(__file__).resolve().with_name('run_headless.sh')),
                                         '--server', 'http://127.0.0.1:1', '--volatile',
                                         '--mcp-profile', str(case / 'profile'), *options],
                                        env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    result.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    result.terminate()
                    try:
                        result.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(result.pid, signal.SIGKILL)
                        result.wait()
                    raise
            text = (case / 'process.log').read_text(errors='replace')
            assert result.returncode == 78, (name, result.returncode)
            assert 'MCP startup failed' in text, name
            assert key not in text, name
            assert not any(runtime.iterdir()), name
            results.append({'case': name, 'exit_code': result.returncode, 'runtime_removed': True})
    finally:
        collision.close()
    (output / 'result.json').write_text(json.dumps(results, indent=2))
    print(json.dumps({'passed': len(results), 'account_used': False}))


if __name__ == '__main__':
    main()
