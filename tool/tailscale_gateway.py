#!/usr/bin/env python3
"""Render the nginx gateway for an existing API and a frozen Web build.

This only writes a configuration. Container lifecycle and Tailscale Serve are
explicit operator steps; it never configures Funnel or reads user credentials.
"""
import argparse
from pathlib import Path
from urllib.parse import urlsplit


def render(api_origin: str, listen_port: int, *, reports: bool = False) -> str:
    parsed = urlsplit(api_origin)
    if (parsed.scheme not in ('http', 'https') or not parsed.hostname
            or parsed.username or parsed.password or parsed.path not in ('', '/')
            or parsed.query or parsed.fragment
            or any(c in api_origin for c in '\r\n\t ;{}$\\"\'')):
        raise ValueError('API origin must be an HTTP(S) origin without credentials, path or nginx syntax')
    if not 1024 <= listen_port <= 65535:
        raise ValueError('listen port must be an unprivileged TCP port')
    template = Path(__file__).resolve().parents[1] / 'deploy/tailscale/nginx.conf.template'
    content = template.read_text().replace('__API_ORIGIN__', api_origin.rstrip('/')).replace(
        '__LISTEN_PORT__', str(listen_port))
    if reports:
        # An explicit read-only mount, never a path supplied by a browser or an API caller.
        marker = '        location / {'
        assert content.count(marker) == 1
        content = content.replace(marker, """        location ^~ /reports/ {
            alias /srv/reports/;
            index index.html;
            autoindex off;
            add_header Cache-Control "no-store" always;
        }
""" + marker)
    return content


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--api-origin', required=True)
    p.add_argument('--listen-port', type=int, default=19197)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--reports', action='store_true', help='Serve an explicit read-only /srv/reports mount under /reports/')
    a = p.parse_args()
    content = render(a.api_origin, a.listen_port, reports=a.reports)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(content)


if __name__ == '__main__':
    main()
