#!/usr/bin/env python3
"""Read-only gate client for a local Streamable HTTP MCP endpoint (stdlib only)."""
import argparse
import json
import pathlib
import urllib.error
import urllib.request


class McpClient:
    def __init__(self, endpoint, token):
        self.endpoint = endpoint
        self.token = token
        self.session = None
        self.counter = 0
        self.version = '2025-11-25'

    def send(self, method, params=None, notification=False):
        self.counter += 1
        message = {'jsonrpc': '2.0', 'method': method}
        if not notification:
            message['id'] = self.counter
        if params is not None:
            message['params'] = params
        headers = {'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json',
                   'Accept': 'application/json, text/event-stream', 'MCP-Protocol-Version': self.version}
        if self.session:
            headers['Mcp-Session-Id'] = self.session
        request = urllib.request.Request(self.endpoint, data=json.dumps(message).encode(), headers=headers)
        with urllib.request.urlopen(request, timeout=45) as response:
            self.session = response.headers.get('Mcp-Session-Id', self.session)
            body = response.read().decode()
            if not body:
                return None
            if response.headers.get('Content-Type', '').startswith('text/event-stream'):
                body = next(line[6:] for line in body.splitlines() if line.startswith('data: '))
            result = json.loads(body)
            if 'error' in result:
                raise RuntimeError('MCP request rejected')
            return result.get('result')

    def initialize(self):
        result = self.send('initialize', {'protocolVersion': self.version, 'capabilities': {},
                                         'clientInfo': {'name': 'dify-sf-checklist-gate', 'version': '0.1.0'}})
        self.version = result['protocolVersion']
        self.send('notifications/initialized', notification=True)

    def check(self, workflow, revision=None):
        arguments = {'workflow_id': workflow}
        if revision is not None:
            arguments['expected_revision'] = revision
        result = self.send('tools/call', {'name': 'check_workflow', 'arguments': arguments})
        if result.get('isError'):
            raise RuntimeError('Workflow check unavailable')
        return result.get('structuredContent') or json.loads(result['content'][0]['text'])

    def close(self):
        if not self.session:
            return
        request = urllib.request.Request(self.endpoint, method='DELETE', headers={
            'Authorization': 'Bearer ' + self.token, 'Mcp-Session-Id': self.session,
            'MCP-Protocol-Version': self.version})
        with urllib.request.urlopen(request, timeout=10):
            pass
        self.session = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--endpoint', default='http://127.0.0.1:39391/mcp')
    parser.add_argument('--token-file', type=pathlib.Path, required=True)
    parser.add_argument('--revision', type=int)
    parser.add_argument('workflow_id')
    args = parser.parse_args()
    if args.token_file.stat().st_mode & 0o077:
        parser.error('token file must be owner-only')
    client = McpClient(args.endpoint, args.token_file.read_text().strip())
    try:
        client.initialize()
        result = client.check(args.workflow_id, args.revision)
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result.get('complete') is True and result.get('gate_passed') is True else 1
    except (OSError, RuntimeError, ValueError, KeyError):
        # Never print HTTP headers, bearer keys, profile or remote error payloads.
        print(json.dumps({'complete': False, 'error': 'check_unavailable'}))
        return 2
    finally:
        try:
            client.close()
        except (OSError, RuntimeError):
            pass


if __name__ == '__main__':
    raise SystemExit(main())
