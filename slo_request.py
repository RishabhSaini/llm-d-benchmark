#!/usr/bin/env python3
"""
Script to send inference requests with TTFT and TPOT SLO headers.
"""

import argparse
import json
import sys
import time
from typing import Optional

import requests


def send_slo_request(
    gateway_url: str,
    model: str,
    prompt: str,
    ttft_slo_ms: Optional[int],
    tpot_slo_ms: Optional[int],
    max_tokens: int = 20,
    temperature: float = 0.0,
    enable_prediction: bool = True,
    stream: bool = False,
    use_completions: bool = False,
) -> None:
    """
    Send an inference request with SLO headers.

    Args:
        gateway_url: The gateway endpoint URL (e.g., http://localhost:8080)
        model: Model name to use
        prompt: The prompt text
        ttft_slo_ms: Time To First Token SLO in milliseconds
        tpot_slo_ms: Time Per Output Token SLO in milliseconds
        max_tokens: Maximum tokens to generate
        temperature: Sampling temperature
        enable_prediction: Enable prediction-based scheduling
        stream: Enable streaming mode
        use_completions: Use /v1/completions endpoint instead of /v1/chat/completions
    """

    # Construct the full URL based on API type
    endpoint = "completions" if use_completions else "chat/completions"
    url = f"{gateway_url}/v1/{endpoint}"

    # Set up headers
    headers = {
        "Content-Type": "application/json",
    }

    if enable_prediction:
        headers["x-prediction-based-scheduling"] = "true"

    if ttft_slo_ms:
        headers["x-slo-ttft-ms"] = str(ttft_slo_ms)

    if tpot_slo_ms:
        headers["x-slo-tpot-ms"] = str(tpot_slo_ms)

    # Request payload - format depends on API type
    if use_completions:
        # Completions API format
        payload = {
            "model": model,
            "prompt": prompt,
            "max_tokens": max_tokens,
        }
    else:
        # Chat completions API format
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
        }

    if temperature is not None:
        payload["temperature"] = temperature

    if stream:
        payload["stream"] = stream
        if not use_completions:  # stream_options only for chat completions
            payload["stream_options"] = {"include_usage": "true"}

    print(f"Sending request to: {url}")
    print(f"Headers: {json.dumps(headers, indent=2)}")
    print(f"Payload: {json.dumps(payload, indent=2)}\n")

    try:
        # Send request
        response = requests.post(
            url,
            headers=headers,
            json=payload,
            stream=stream,
            timeout=300,  # 5 minute timeout
        )

        response.raise_for_status()

        if stream:
            # Handle streaming response (SSE)
            print("=" * 80)
            print("STREAMING RESPONSE:")
            print("=" * 80)

            first_token_time = None
            token_times = []
            tokens_received = 0
            full_text = ""

            for line in response.iter_lines(decode_unicode=True):
                if not line:
                    continue

                # SSE format: "data: {json}"
                if line.startswith("data: "):
                    data_str = line[6:]  # Remove "data: " prefix

                    if data_str == "[DONE]":
                        print("\n[DONE]")
                        break

                    try:
                        data = json.loads(data_str)

                        # Track timing
                        current_time = time.time()
                        if first_token_time is None:
                            first_token_time = current_time
                        else:
                            token_times.append(current_time)

                        # Print token (chat format uses "delta" or "message")
                        if "choices" in data and len(data["choices"]) > 0:
                            choice = data["choices"][0]
                            # Try delta first (streaming), then message, then text (fallback)
                            text = ""
                            if "delta" in choice and "content" in choice["delta"]:
                                text = choice["delta"]["content"]
                            elif "message" in choice and "content" in choice["message"]:
                                text = choice["message"]["content"]
                            elif "text" in choice:
                                text = choice["text"]

                            if text:
                                print(text, end="", flush=True)
                                full_text += text
                                tokens_received += 1

                        # Check for usage data (final frame)
                        if "usage" in data:
                            print("\n\n" + "=" * 80)
                            print("USAGE METRICS:")
                            print("=" * 80)
                            usage = data["usage"]
                            print(json.dumps(usage, indent=2))

                            # Display SLO comparison (only if usage is not None)
                            if usage and ("ttft_ms" in usage or "predicted_ttft_ms" in usage):
                                print("\n" + "=" * 80)
                                print("SLO ANALYSIS:")
                                print("=" * 80)

                                if "ttft_ms" in usage and "predicted_ttft_ms" in usage:
                                    actual_ttft = usage["ttft_ms"]
                                    predicted_ttft = usage["predicted_ttft_ms"]
                                    if ttft_slo_ms is not None:
                                        print(f"TTFT SLO:       {ttft_slo_ms} ms")
                                    else:
                                        print(f"TTFT SLO:       Not specified")
                                    print(f"Actual TTFT:    {actual_ttft} ms")
                                    print(f"Predicted TTFT: {predicted_ttft:.2f} ms")
                                    if ttft_slo_ms is not None:
                                        print(f"TTFT Met:       {'✓' if actual_ttft <= ttft_slo_ms else '✗'}")
                                    print(f"Prediction Acc: {abs(predicted_ttft - actual_ttft):.2f} ms error")

                                if "avg_tpot_ms" in usage and "avg_predicted_tpot_ms" in usage:
                                    actual_tpot = usage["avg_tpot_ms"]
                                    predicted_tpot = usage["avg_predicted_tpot_ms"]
                                    if tpot_slo_ms is not None:
                                        print(f"\nTPOT SLO:       {tpot_slo_ms} ms")
                                    else:
                                        print(f"\nTPOT SLO:       Not specified")
                                    print(f"Actual TPOT:    {actual_tpot} ms")
                                    print(f"Predicted TPOT: {predicted_tpot:.2f} ms")
                                    if tpot_slo_ms is not None:
                                        print(f"TPOT Met:       {'✓' if actual_tpot <= tpot_slo_ms else '✗'}")
                                    print(f"Prediction Acc: {abs(predicted_tpot - actual_tpot):.2f} ms error")

                    except json.JSONDecodeError as e:
                        print(f"\nWarning: Could not parse JSON: {e}")
                        print(f"Raw data: {data_str}")

            print("=" * 80)
            print(f"Total tokens received: {tokens_received}")

        else:
            # Handle non-streaming response
            data = response.json()
            print("=" * 80)
            print("RESPONSE:")
            print("=" * 80)
            print(json.dumps(data, indent=2))

    except requests.exceptions.RequestException as e:
        print(f"Error making request: {e}", file=sys.stderr)
        if hasattr(e, "response") and e.response is not None:
            print(f"Response status: {e.response.status_code}", file=sys.stderr)
            print(f"Response body: {e.response.text}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Send inference requests with TTFT and TPOT SLO headers",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic request with SLOs (uses chat/completions by default)
  python slo_request.py

  # Use completions endpoint instead of chat/completions
  python slo_request.py --use-completions

  # Request without any SLO headers
  python slo_request.py --no-slo

  # Custom prompt with SLOs
  python slo_request.py \\
    --ttft-slo 200 --tpot-slo 50 \\
    --prompt "What is Kubernetes?"

  # Request without prediction-based scheduling
  python slo_request.py --no-prediction

  # With streaming enabled (chat/completions)
  python slo_request.py --stream

  # Completions endpoint with streaming
  python slo_request.py --use-completions --stream

  # No SLOs with streaming
  python slo_request.py --no-slo --stream
        """,
    )

    parser.add_argument(
        "--gateway",
        default="http://localhost:8080",
        help="Gateway URL (default: http://localhost:8080)",
    )
    parser.add_argument(
        "--model",
        default="openai/gpt-oss-120b",
        help="Model name (default: openai/gpt-oss-120b)",
    )
    parser.add_argument(
        "--prompt",
        default="hello, whats ur name in hindi and japanese?",
        help="Prompt text",
    )
    parser.add_argument(
        "--ttft-slo",
        type=int,
        default=200,
        help="Time To First Token SLO in milliseconds (default: 200, set to 0 to disable)",
    )
    parser.add_argument(
        "--tpot-slo",
        type=int,
        default=50,
        help="Time Per Output Token SLO in milliseconds (default: 50, set to 0 to disable)",
    )
    parser.add_argument(
        "--no-slo",
        action="store_true",
        help="Disable all SLO headers (overrides --ttft-slo and --tpot-slo)",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=50,
        help="Maximum tokens to generate (default: 20)",
    )
    parser.add_argument(
        "--temperature",
        type=float,
        default=0.0,
        help="Sampling temperature (default: 0.0)",
    )
    parser.add_argument(
        "--no-prediction",
        action="store_true",
        help="Disable prediction-based scheduling",
    )
    parser.add_argument(
        "--stream",
        action="store_true",
        help="Enable streaming mode (disabled by default)",
    )
    parser.add_argument(
        "--use-completions",
        action="store_true",
        help="Use /v1/completions endpoint instead of /v1/chat/completions (default: chat/completions)",
    )

    args = parser.parse_args()

    # Handle --no-slo flag
    ttft_slo = None if args.no_slo else (args.ttft_slo if args.ttft_slo > 0 else None)
    tpot_slo = None if args.no_slo else (args.tpot_slo if args.tpot_slo > 0 else None)

    send_slo_request(
        gateway_url=args.gateway,
        model=args.model,
        prompt=args.prompt,
        ttft_slo_ms=ttft_slo,
        tpot_slo_ms=tpot_slo,
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        enable_prediction=not args.no_prediction,
        stream=args.stream,
        use_completions=args.use_completions,
    )


if __name__ == "__main__":
    main()
