#!/usr/bin/env python3
"""Prepare, never install, a one-client/one-tailnet-IP/one-port Squid exception."""
import argparse
import ipaddress
from pathlib import Path


def prepare(configuration: str, client_ip: str, destination_ip: str, destination_port: int) -> str:
    client = ipaddress.IPv4Address(client_ip)
    destination = ipaddress.IPv4Address(destination_ip)
    if not client.is_private or client.is_loopback or client.is_unspecified:
        raise ValueError('client must be the inspected private IPv4 address of the API container')
    if destination not in ipaddress.IPv4Network('100.64.0.0/10'):
        raise ValueError('destination must be one IPv4 Tailscale address, not a network or hostname')
    if destination_port not in (80, 443) and not 1025 <= destination_port <= 65535:
        raise ValueError('destination port must already be in Safe_ports (80, 443, 1025..65535)')
    anchor = 'http_access deny CONNECT !SSL_ports'
    if configuration.splitlines().count(anchor) != 1:
        raise ValueError('expected exactly one upstream CONNECT policy anchor')
    if 'approved_runtime_' in configuration:
        raise ValueError('an exception already exists; do not accumulate unreviewed rules')
    block = '\n'.join([
        '# Explicit deployment exception; regenerate after an API container address change.',
        f'acl approved_runtime_client src {client}/32',
        f'acl approved_runtime_host dst {destination}/32',
        f'acl approved_runtime_port port {destination_port}',
        'http_access allow approved_runtime_client approved_runtime_host approved_runtime_port',
    ])
    # Keep !Safe_ports first. Allow CONNECT on the one approved port without broadening SSL_ports globally.
    if configuration.index('http_access deny !Safe_ports') > configuration.index(anchor):
        raise ValueError('unexpected Safe_ports ordering')
    if configuration.index(anchor) > configuration.index('http_access deny to_private_networks'):
        raise ValueError('unexpected private destination policy ordering')
    return configuration.replace(anchor, block + '\n' + anchor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--client-ip', required=True)
    parser.add_argument('--destination-ip', required=True)
    parser.add_argument('--destination-port', required=True, type=int)
    args = parser.parse_args()
    result = prepare(args.input.read_text(), args.client_ip, args.destination_ip, args.destination_port)
    # New review file only; never overwrite an active configuration or silently replace another proposal.
    with args.output.open('x') as stream:
        stream.write(result)


if __name__ == '__main__':
    main()
