#!/usr/bin/env python3
"""
GuideLLM SLO Header Injection Wrapper

Monkey-patches httpx.AsyncClient to inject SLO headers into all requests.
This is a workaround for GuideLLM 0.5.0 which doesn't support custom headers
via --backend-args (that feature was added in a later commit but then removed
during refactoring).

Usage:
    Set environment variables SLO_TTFT_MS and SLO_TPOT_MS, then run:
    python slo_header_injector.py benchmark run [...]
"""
import sys
import os
import httpx

# Get SLO headers from environment (read once at startup)
TTFT_SLO = os.getenv('SLO_TTFT_MS')
TPOT_SLO = os.getenv('SLO_TPOT_MS')

# Store original methods
_original_build_request = httpx.AsyncClient.build_request
_original_send = httpx.AsyncClient.send

def patched_build_request(self, method, url, **kwargs):
    """Inject SLO headers when building requests"""
    if TTFT_SLO or TPOT_SLO:
        headers = kwargs.get('headers')

        # Convert to mutable dict
        if headers is None:
            headers = {}
        elif isinstance(headers, httpx.Headers):
            headers = dict(headers)
        elif hasattr(headers, '__iter__') and not isinstance(headers, dict):
            headers = dict(headers)
        else:
            headers = dict(headers)

        # Inject SLO headers
        if TTFT_SLO:
            headers['x-slo-ttft-ms'] = TTFT_SLO
        if TPOT_SLO:
            headers['x-slo-tpot-ms'] = TPOT_SLO

        kwargs['headers'] = headers

    # Call original method
    return _original_build_request(self, method, url, **kwargs)

async def patched_send(self, request, **kwargs):
    """Inject SLO headers when sending requests (fallback)"""
    if TTFT_SLO or TPOT_SLO:
        # Ensure headers exist in the request
        if TTFT_SLO and 'x-slo-ttft-ms' not in request.headers:
            request.headers['x-slo-ttft-ms'] = TTFT_SLO
        if TPOT_SLO and 'x-slo-tpot-ms' not in request.headers:
            request.headers['x-slo-tpot-ms'] = TPOT_SLO

        # Log header injection (to stderr)
        print(
            f"[SLO Wrapper] Headers in request: x-slo-ttft-ms={request.headers.get('x-slo-ttft-ms')}, "
            f"x-slo-tpot-ms={request.headers.get('x-slo-tpot-ms')}, URL={request.url}",
            file=sys.stderr
        )

    # Call original send method
    return await _original_send(self, request, **kwargs)

# Apply the monkey patches BEFORE importing guidellm
httpx.AsyncClient.build_request = patched_build_request
httpx.AsyncClient.send = patched_send

if TTFT_SLO or TPOT_SLO:
    print(
        f"[SLO Wrapper] Initialized with TTFT={TTFT_SLO}ms, TPOT={TPOT_SLO}ms",
        file=sys.stderr
    )

# Now import and run guidellm CLI
from guidellm.__main__ import cli

if __name__ == '__main__':
    sys.exit(cli())
