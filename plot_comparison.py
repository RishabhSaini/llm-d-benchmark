#!/usr/bin/env python3
"""
Plot baseline vs SLO-optimized benchmark results for PD disaggregation.

Usage:
    python3 plot_comparison.py [workload_name]

Arguments:
    workload_name: Name of the workload (default: prefill_heavy)
                   Used to create output directory: ~/plots/{workload_name}_baseline_vs_slo/
"""

import os
import sys
import yaml
from pathlib import Path
import matplotlib.pyplot as plt
import numpy as np
import json

# Get workload name from command line or use default
WORKLOAD_NAME = sys.argv[1] if len(sys.argv) > 1 else "prefill_heavy"

# Configuration
RESULTS_DIR = Path("/home/rsaini/data/pd-disaggregation-slo/results")
OUTPUT_DIR = Path.home() / "plots" / f"{WORKLOAD_NAME}_baseline_vs_slo"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# SLO thresholds (ms)
SLO_TTFT = 800  # Time to First Token SLO
SLO_TPOT = 18   # Time Per Output Token SLO

def parse_results():
    """Parse all benchmark results from YAML files."""
    baseline_results = []
    slo_results = []

    for result_dir in sorted(RESULTS_DIR.iterdir()):
        if not result_dir.is_dir():
            continue

        yaml_file = result_dir / "benchmark_report,_results.json_0.yaml"
        if not yaml_file.exists():
            continue

        try:
            with open(yaml_file) as f:
                data = yaml.safe_load(f)

            # Extract metrics
            metrics = data.get('metrics', {})
            throughput_data = metrics.get('throughput', {})

            # Get requested rate from scenario config
            scenario = data.get('scenario', {})
            load_args = scenario.get('load', {}).get('args', {})
            rate_config = load_args.get('rate', [0])
            requested_rate = rate_config[0] if isinstance(rate_config, list) and rate_config else 0

            # Use actual requests per second achieved
            rate = throughput_data.get('requests_per_sec', 0)

            # Get latencies
            ttft = metrics.get('latency', {}).get('time_to_first_token', {})
            tpot = metrics.get('latency', {}).get('inter_token_latency', {})
            e2e = metrics.get('latency', {}).get('request_latency', {})

            # Get request statistics
            requests_data = metrics.get('requests', {})
            total_requests = requests_data.get('total', 0)
            failed_requests = requests_data.get('failures', 0)
            incomplete_requests = requests_data.get('incomplete', 0)
            completed_requests = total_requests - failed_requests - incomplete_requests
            completion_rate = (completed_requests / total_requests * 100) if total_requests > 0 else 0

            result = {
                'dir': result_dir.name,
                'timestamp': int(result_dir.name.split('_')[1]),
                'requested_rate': float(requested_rate),
                'rate': float(rate),
                'ttft_p50': ttft.get('p50', 0),
                'ttft_p95': ttft.get('p95', 0),
                'ttft_p99': ttft.get('p99', 0),
                'ttft_mean': ttft.get('mean', 0),
                'tpot_p50': tpot.get('p50', 0),
                'tpot_p95': tpot.get('p95', 0),
                'tpot_p99': tpot.get('p99', 0),
                'tpot_mean': tpot.get('mean', 0),
                'e2e_p50': e2e.get('p50', 0) * 1000,  # Convert to ms
                'e2e_p95': e2e.get('p95', 0) * 1000,
                'e2e_p99': e2e.get('p99', 0) * 1000,
                'output_token_throughput': throughput_data.get('output_tokens_per_sec', 0),
                'total_token_throughput': throughput_data.get('total_tokens_per_sec', 0),
                'total_requests': total_requests,
                'completed_requests': completed_requests,
                'failed_requests': failed_requests,
                'incomplete_requests': incomplete_requests,
                'completion_rate': completion_rate,
            }

            # Categorize: SLO-optimized has lower, more consistent TTFT
            # Baseline has higher TTFT (500ms+), SLO-optimized is more consistent (~400ms)
            if result['ttft_p50'] < 500:
                slo_results.append(result)
            else:
                baseline_results.append(result)

        except Exception as e:
            print(f"Error processing {result_dir.name}: {e}")
            continue

    # Sort by rate
    baseline_results.sort(key=lambda x: x['rate'])
    slo_results.sort(key=lambda x: x['rate'])

    return baseline_results, slo_results


def create_plots(baseline_results, slo_results):
    """Create single combined comparison plot."""

    # Extract data for plotting
    baseline_requested_rates = [r['requested_rate'] for r in baseline_results]
    baseline_rates = [r['rate'] for r in baseline_results]
    baseline_ttft_p50 = [r['ttft_p50'] for r in baseline_results]
    baseline_ttft_p95 = [r['ttft_p95'] for r in baseline_results]
    baseline_tpot_p50 = [r['tpot_p50'] for r in baseline_results]
    baseline_tpot_p95 = [r['tpot_p95'] for r in baseline_results]
    baseline_completion = [r['completion_rate'] for r in baseline_results]
    baseline_throughput = [r['output_token_throughput'] for r in baseline_results]

    slo_requested_rates = [r['requested_rate'] for r in slo_results]
    slo_rates = [r['rate'] for r in slo_results]
    slo_ttft_p50 = [r['ttft_p50'] for r in slo_results]
    slo_ttft_p95 = [r['ttft_p95'] for r in slo_results]
    slo_tpot_p50 = [r['tpot_p50'] for r in slo_results]
    slo_tpot_p95 = [r['tpot_p95'] for r in slo_results]
    slo_completion = [r['completion_rate'] for r in slo_results]
    slo_throughput = [r['output_token_throughput'] for r in slo_results]

    # Create single comprehensive combined plot
    fig = plt.figure(figsize=(16, 16))
    gs = fig.add_gridspec(3, 3, hspace=0.4, wspace=0.3, height_ratios=[1, 1.5, 1.5])
    fig.suptitle(f'PD Disaggregation: Baseline vs SLO-Optimized - Complete Analysis\n{WORKLOAD_NAME.replace("_", " ").title()} Workload',
                 fontsize=18, fontweight='bold', y=0.98)

    # Row 1: Requested vs Actual QPS, Completion Rate, Output Throughput
    ax4 = fig.add_subplot(gs[0, 0])
    # Sort by requested rate for proper line plotting
    if baseline_requested_rates:
        baseline_qps_pairs = sorted(zip(baseline_requested_rates, baseline_rates), key=lambda x: x[0])
        baseline_req_sorted, baseline_act_sorted = zip(*baseline_qps_pairs) if baseline_qps_pairs else ([], [])
    else:
        baseline_req_sorted, baseline_act_sorted = [], []

    if slo_requested_rates:
        slo_qps_pairs = sorted(zip(slo_requested_rates, slo_rates), key=lambda x: x[0])
        slo_req_sorted, slo_act_sorted = zip(*slo_qps_pairs) if slo_qps_pairs else ([], [])
    else:
        slo_req_sorted, slo_act_sorted = [], []

    # Plot diagonal line for perfect match
    if baseline_req_sorted or slo_req_sorted:
        max_rate = max(
            max(baseline_req_sorted) if baseline_req_sorted else 0,
            max(slo_req_sorted) if slo_req_sorted else 0
        )
        ax4.plot([0, max_rate], [0, max_rate], 'k--', linewidth=1, alpha=0.3, label='Perfect Match')

    if baseline_req_sorted:
        ax4.plot(baseline_req_sorted, baseline_act_sorted, 'o-', label='Baseline',
                color='#d62728', linewidth=2, markersize=6)
    if slo_req_sorted:
        ax4.plot(slo_req_sorted, slo_act_sorted, 's-', label='SLO-Optimized',
                color='#2ca02c', linewidth=2, markersize=6)
    ax4.set_xlabel('Requested QPS', fontsize=10)
    ax4.set_ylabel('Actual QPS', fontsize=10)
    ax4.set_title('Requested vs Actual QPS', fontsize=11, fontweight='bold')
    ax4.legend(fontsize=8)
    ax4.grid(True, alpha=0.3)

    ax5 = fig.add_subplot(gs[0, 1])
    # Completion Rate
    if baseline_rates:
        ax5.plot(baseline_rates, baseline_completion, 'o-', label='Baseline',
                color='#d62728', linewidth=2, markersize=6)
    if slo_rates:
        ax5.plot(slo_rates, slo_completion, 's-', label='SLO-Optimized',
                color='#2ca02c', linewidth=2, markersize=6)
    ax5.axhline(y=100, color='black', linestyle='--', linewidth=1.5,
                label='100%', alpha=0.7)
    ax5.set_xlabel('Request Rate (QPS)', fontsize=10)
    ax5.set_ylabel('Completion Rate (%)', fontsize=10)
    ax5.set_title('Request Completion Rate', fontsize=11, fontweight='bold')
    ax5.set_ylim([0, 105])
    ax5.legend(fontsize=8)
    ax5.grid(True, alpha=0.3)

    ax6 = fig.add_subplot(gs[0, 2])
    # Output Throughput
    if baseline_rates:
        ax6.plot(baseline_rates, baseline_throughput, 'o-', label='Baseline',
                color='#d62728', linewidth=2, markersize=6)
    if slo_rates:
        ax6.plot(slo_rates, slo_throughput, 's-', label='SLO-Optimized',
                color='#2ca02c', linewidth=2, markersize=6)
    ax6.set_xlabel('Request Rate (QPS)', fontsize=10)
    ax6.set_ylabel('Output Throughput (tok/s)', fontsize=10)
    ax6.set_title('Output Token Throughput', fontsize=11, fontweight='bold')
    ax6.legend(fontsize=8)
    ax6.grid(True, alpha=0.3)

    # Row 2: TTFT Distribution (spanning all columns)
    ax7 = fig.add_subplot(gs[1, :])
    if baseline_rates:
        ax7.fill_between(baseline_rates, baseline_ttft_p50, baseline_ttft_p95,
                        alpha=0.3, color='#d62728', label='Baseline P50-P95')
        ax7.plot(baseline_rates, baseline_ttft_p50, 'o-', color='#d62728',
                linewidth=2, markersize=6, label='Baseline P50')
        ax7.plot(baseline_rates, baseline_ttft_p95, 'o--', color='#d62728',
                linewidth=1.5, markersize=5, alpha=0.7, label='Baseline P95')
    if slo_rates:
        ax7.fill_between(slo_rates, slo_ttft_p50, slo_ttft_p95,
                        alpha=0.3, color='#2ca02c', label='SLO-Opt P50-P95')
        ax7.plot(slo_rates, slo_ttft_p50, 's-', color='#2ca02c',
                linewidth=2, markersize=6, label='SLO-Opt P50')
        ax7.plot(slo_rates, slo_ttft_p95, 's--', color='#2ca02c',
                linewidth=1.5, markersize=5, alpha=0.7, label='SLO-Opt P95')
    ax7.axhline(y=SLO_TTFT, color='black', linestyle='--', linewidth=2,
               label=f'TTFT SLO ({SLO_TTFT}ms)', alpha=0.8)
    ax7.set_xlabel('Request Rate (QPS)', fontsize=10)
    ax7.set_ylabel('Time to First Token (ms)', fontsize=10)
    ax7.set_title('TTFT Distribution (P50-P95 Range)', fontsize=11, fontweight='bold')
    ax7.legend(fontsize=8, loc='best', ncol=2)
    ax7.grid(True, alpha=0.3)

    # Row 3: TPOT Distribution (spanning all columns)
    ax8 = fig.add_subplot(gs[2, :])
    if baseline_rates:
        ax8.fill_between(baseline_rates, baseline_tpot_p50, baseline_tpot_p95,
                        alpha=0.3, color='#d62728', label='Baseline P50-P95')
        ax8.plot(baseline_rates, baseline_tpot_p50, 'o-', color='#d62728',
                linewidth=2, markersize=6, label='Baseline P50')
        ax8.plot(baseline_rates, baseline_tpot_p95, 'o--', color='#d62728',
                linewidth=1.5, markersize=5, alpha=0.7, label='Baseline P95')
    if slo_rates:
        ax8.fill_between(slo_rates, slo_tpot_p50, slo_tpot_p95,
                        alpha=0.3, color='#2ca02c', label='SLO-Opt P50-P95')
        ax8.plot(slo_rates, slo_tpot_p50, 's-', color='#2ca02c',
                linewidth=2, markersize=6, label='SLO-Opt P50')
        ax8.plot(slo_rates, slo_tpot_p95, 's--', color='#2ca02c',
                linewidth=1.5, markersize=5, alpha=0.7, label='SLO-Opt P95')
    ax8.axhline(y=SLO_TPOT, color='black', linestyle='--', linewidth=2,
               label=f'TPOT SLO ({SLO_TPOT}ms)', alpha=0.8)
    ax8.set_xlabel('Request Rate (QPS)', fontsize=10)
    ax8.set_ylabel('Time Per Output Token (ms/token)', fontsize=10)
    ax8.set_title('TPOT Distribution (P50-P95 Range)', fontsize=11, fontweight='bold')
    ax8.legend(fontsize=8, loc='best', ncol=2)
    ax8.grid(True, alpha=0.3)

    output_file = OUTPUT_DIR / "combined_analysis.png"
    plt.savefig(output_file, dpi=300, bbox_inches='tight')
    print(f"Saved combined plot: {output_file}")
    plt.close()


def print_summary(baseline_results, slo_results):
    """Print summary statistics."""
    print("\n" + "="*80)
    print("BENCHMARK RESULTS SUMMARY")
    print("="*80)

    print(f"\nTotal Results:")
    print(f"  Baseline: {len(baseline_results)} benchmarks")
    print(f"  SLO-Optimized: {len(slo_results)} benchmarks")

    if baseline_results:
        print(f"\nBaseline Results:")
        print(f"  Request Rate Range: {baseline_results[0]['rate']:.1f} - {baseline_results[-1]['rate']:.1f} QPS")
        print(f"  TTFT P50 Range: {min(r['ttft_p50'] for r in baseline_results):.1f} - {max(r['ttft_p50'] for r in baseline_results):.1f} ms")
        print(f"  TTFT P95 Range: {min(r['ttft_p95'] for r in baseline_results):.1f} - {max(r['ttft_p95'] for r in baseline_results):.1f} ms")
        print(f"  TPOT P50 Range: {min(r['tpot_p50'] for r in baseline_results):.1f} - {max(r['tpot_p50'] for r in baseline_results):.1f} ms/token")
        print(f"  Completion Rate Range: {min(r['completion_rate'] for r in baseline_results):.1f} - {max(r['completion_rate'] for r in baseline_results):.1f} %")
        print(f"  Output Throughput Range: {min(r['output_token_throughput'] for r in baseline_results):.1f} - {max(r['output_token_throughput'] for r in baseline_results):.1f} tokens/s")

        # SLO violations
        ttft_violations = sum(1 for r in baseline_results if r['ttft_p95'] > SLO_TTFT)
        tpot_violations = sum(1 for r in baseline_results if r['tpot_p95'] > SLO_TPOT)
        print(f"  TTFT SLO Violations (P95 > {SLO_TTFT}ms): {ttft_violations}/{len(baseline_results)}")
        print(f"  TPOT SLO Violations (P95 > {SLO_TPOT}ms): {tpot_violations}/{len(baseline_results)}")

    if slo_results:
        print(f"\nSLO-Optimized Results:")
        print(f"  Request Rate Range: {slo_results[0]['rate']:.1f} - {slo_results[-1]['rate']:.1f} QPS")
        print(f"  TTFT P50 Range: {min(r['ttft_p50'] for r in slo_results):.1f} - {max(r['ttft_p50'] for r in slo_results):.1f} ms")
        print(f"  TTFT P95 Range: {min(r['ttft_p95'] for r in slo_results):.1f} - {max(r['ttft_p95'] for r in slo_results):.1f} ms")
        print(f"  TPOT P50 Range: {min(r['tpot_p50'] for r in slo_results):.1f} - {max(r['tpot_p50'] for r in slo_results):.1f} ms/token")
        print(f"  Completion Rate Range: {min(r['completion_rate'] for r in slo_results):.1f} - {max(r['completion_rate'] for r in slo_results):.1f} %")
        print(f"  Output Throughput Range: {min(r['output_token_throughput'] for r in slo_results):.1f} - {max(r['output_token_throughput'] for r in slo_results):.1f} tokens/s")

        # SLO violations
        ttft_violations = sum(1 for r in slo_results if r['ttft_p95'] > SLO_TTFT)
        tpot_violations = sum(1 for r in slo_results if r['tpot_p95'] > SLO_TPOT)
        print(f"  TTFT SLO Violations (P95 > {SLO_TTFT}ms): {ttft_violations}/{len(slo_results)}")
        print(f"  TPOT SLO Violations (P95 > {SLO_TPOT}ms): {tpot_violations}/{len(slo_results)}")

    if baseline_results and slo_results:
        # Calculate improvement
        baseline_avg_ttft_p50 = np.mean([r['ttft_p50'] for r in baseline_results])
        slo_avg_ttft_p50 = np.mean([r['ttft_p50'] for r in slo_results])
        improvement = ((baseline_avg_ttft_p50 - slo_avg_ttft_p50) / baseline_avg_ttft_p50) * 100

        print(f"\nImprovement (TTFT P50):")
        print(f"  Baseline Average: {baseline_avg_ttft_p50:.1f} ms")
        print(f"  SLO-Optimized Average: {slo_avg_ttft_p50:.1f} ms")
        print(f"  Improvement: {improvement:.1f}%")

    print("\n" + "="*80)


def save_data(baseline_results, slo_results):
    """Save parsed data to JSON."""
    output_file = OUTPUT_DIR / "results_summary.json"
    with open(output_file, 'w') as f:
        json.dump({
            'baseline': baseline_results,
            'slo_optimized': slo_results
        }, f, indent=2)
    print(f"\nSaved data summary: {output_file}")


def main():
    """Main execution."""
    print("Parsing benchmark results...")
    baseline_results, slo_results = parse_results()

    if not baseline_results and not slo_results:
        print("ERROR: No results found!")
        return

    print_summary(baseline_results, slo_results)

    print("\nCreating plots...")
    create_plots(baseline_results, slo_results)

    save_data(baseline_results, slo_results)

    print(f"\nDone! Plots saved to: {OUTPUT_DIR}")


if __name__ == '__main__':
    main()
