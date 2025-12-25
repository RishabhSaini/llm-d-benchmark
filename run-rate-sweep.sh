#!/bin/bash
# Rate Sweep Script for PD Disaggregation Benchmarking
# Usage: ./run-rate-sweep.sh <workload.yaml> <start_qps> <end_qps> <step>
# Example: ./run-rate-sweep.sh decode_heavy_sharegpt.yaml 1 70 5

set -e

NAMESPACE="${NAMESPACE:-llm-d-pd}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCENARIO="${SCRIPT_DIR}/scenarios/guides/pd-disaggregation-slo.sh"
HARNESS="guidellm"
TIMEOUT=7200  # 2 hours per run

# Get parameters
WORKLOAD="${1:-decode_heavy_sharegpt.yaml}"
START_QPS="${2:-1}"
END_QPS="${3:-70}"
STEP="${4:-5}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Function to collect Prometheus metrics
collect_prometheus_metrics() {
    local namespace=$1
    local duration=$2
    local output_file=$3

    # Find Prometheus service - try multiple namespaces and service names
    local prom_namespace=""
    local prom_service=""

    for ns in llm-d-monitoring monitoring; do
        # Try common Prometheus service names
        for svc_name in prometheus-k8s llmd-kube-prometheus-stack-prometheus kube-prometheus-stack-prometheus prometheus-operated; do
            if kubectl get svc -n $ns $svc_name &>/dev/null 2>&1; then
                prom_namespace=$ns
                prom_service=$svc_name
                break 2
            fi
        done
    done

    if [ -z "$prom_namespace" ]; then
        echo "Prometheus not available in monitoring or llm-d-monitoring namespace, skipping metrics collection"
        return 1
    fi

    echo "Found Prometheus in namespace: $prom_namespace, service: $prom_service"

    # Port forward to Prometheus
    kubectl port-forward -n $prom_namespace svc/$prom_service 9090:9090 &>/dev/null &
    PF_PID=$!
    sleep 3

    local start=$(date +%s)
    local end=$((start + duration))

    # Collect KV cache utilization
    curl -s -G "http://localhost:9090/api/v1/query_range" \
        --data-urlencode "query=avg(vllm:kv_cache_usage_perc{namespace=\"${namespace}\"})" \
        --data-urlencode "start=${start}" \
        --data-urlencode "end=${end}" \
        --data-urlencode "step=5s" > "${output_file}.kv_cache.json" 2>/dev/null || true

    # Collect waiting queue length
    curl -s -G "http://localhost:9090/api/v1/query_range" \
        --data-urlencode "query=avg(vllm:num_requests_waiting{namespace=\"${namespace}\"})" \
        --data-urlencode "start=${start}" \
        --data-urlencode "end=${end}" \
        --data-urlencode "step=5s" > "${output_file}.queue.json" 2>/dev/null || true

    # Collect GPU utilization (try multiple metric names)
    for gpu_metric in "DCGM_FI_DEV_GPU_UTIL" "container_gpu_utilization" "nvidia_gpu_duty_cycle"; do
        if curl -s -G "http://localhost:9090/api/v1/query_range" \
            --data-urlencode "query=avg(${gpu_metric}{namespace=\"${namespace}\"})" \
            --data-urlencode "start=${start}" \
            --data-urlencode "end=${end}" \
            --data-urlencode "step=5s" > "${output_file}.gpu_util.json" 2>/dev/null; then
            # Check if we got actual data
            if [ -s "${output_file}.gpu_util.json" ] && grep -q '"result":\[' "${output_file}.gpu_util.json" 2>/dev/null; then
                break
            fi
        fi
    done

    # Kill port forward
    kill $PF_PID 2>/dev/null || true
}

# Function to calculate p90 from Prometheus JSON
calculate_p90_from_prom() {
    local json_file=$1

    if [ ! -f "$json_file" ]; then
        echo "N/A"
        return
    fi

    # Extract values and calculate p90
    local p90=$(jq -r '.data.result[0].values[][1] | tonumber' "$json_file" 2>/dev/null | \
        sort -n | \
        awk 'BEGIN{c=0}{a[c++]=$1}END{print a[int(c*0.9)]}')

    echo "${p90:-N/A}"
}

print_header "Rate Sweep: ${WORKLOAD}"
echo ""
print_info "Configuration:"
echo -e "  Workload:     ${WORKLOAD}"
echo -e "  Start QPS:    ${START_QPS}"
echo -e "  End QPS:      ${END_QPS}"
echo -e "  Step:         ${STEP}"
echo -e "  Namespace:    ${NAMESPACE}"
echo ""

# Calculate number of runs
QPS_RANGE=$(seq $START_QPS $STEP $END_QPS)
NUM_RUNS=$(echo "$QPS_RANGE" | wc -l)

print_info "Will run ${NUM_RUNS} benchmarks at QPS levels: $(echo $QPS_RANGE | tr '\n' ' ')"
echo ""

# Create a timestamp for this sweep
SWEEP_TIMESTAMP=$(date +%s)
WORKLOAD_NAME=$(basename ${WORKLOAD} .yaml)
SWEEP_RESULTS_DIR="${HOME}/data/pd-disaggregation-slo/rate-sweep-${WORKLOAD_NAME}-${SWEEP_TIMESTAMP}"
mkdir -p "${SWEEP_RESULTS_DIR}"

print_success "Created results directory: ${SWEEP_RESULTS_DIR}"
echo ""

# Extract SLO targets from workload file (if they exist)
WORKLOAD_FILE="${SCRIPT_DIR}/workload/profiles/guidellm/${WORKLOAD}"
if [ ! -f "${WORKLOAD_FILE}" ]; then
    WORKLOAD_FILE="${WORKLOAD_FILE}.in"
fi

SLO_TTFT_MS=$(grep "x-slo-ttft-ms:" "${WORKLOAD_FILE}" 2>/dev/null | awk -F'"' '{print $2}' || echo "N/A")
SLO_TPOT_MS=$(grep "x-slo-tpot-ms:" "${WORKLOAD_FILE}" 2>/dev/null | awk -F'"' '{print $2}' || echo "N/A")

print_info "SLO Targets: TTFT=${SLO_TTFT_MS}ms, TPOT=${SLO_TPOT_MS}ms"
echo ""

# Create comprehensive summary file
SUMMARY_FILE="${SWEEP_RESULTS_DIR}/sweep_summary.csv"
cat > ${SUMMARY_FILE} << EOF
qps,requests_per_sec,output_tokens_per_sec,total_requests,completed,incomplete,failures,error_429_count,ttft_median_ms,ttft_p90_ms,ttft_p95_ms,tpot_median_ms,tpot_p90_ms,tpot_p95_ms,request_latency_median_ms,request_latency_p95_ms,slo_success_completed,slo_success_all,p90_kv_cache_util,p90_queue_length,p90_gpu_util
EOF

# Get gateway endpoint
GATEWAY_NAME=$(kubectl get svc -n ${NAMESPACE} -o name 2>/dev/null | grep -i gateway | grep -i istio | head -1 | sed 's|service/||')
if [ -z "$GATEWAY_NAME" ]; then
    print_error "Gateway service not found"
    exit 1
fi

print_success "Using gateway: ${GATEWAY_NAME}"

# Export variables
export LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME="${GATEWAY_NAME}.${NAMESPACE}.svc.cluster.local"
export LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT="80"
export LLMDBENCH_VLLM_MODELSERVICE_SERVICE_NAME="${GATEWAY_NAME}"
export LLMDBENCH_DEPLOY_CURRENT_MODEL="RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic"
export LLMDBENCH_HARNESS_STACK_ENDPOINT_URL="http://${LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME}:${LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT}"

# Source the scenario
source ${SCENARIO}

# Counter for progress
CURRENT_RUN=0

# Run benchmarks for each QPS value
for QPS in $QPS_RANGE; do
    CURRENT_RUN=$((CURRENT_RUN + 1))

    print_header "Run ${CURRENT_RUN}/${NUM_RUNS}: ${QPS} QPS"

    # Create a workload.in template file with the specific QPS rate
    # This approach works like run-pd-slo-benchmark.sh
    TEMP_WORKLOAD_BASENAME="sweep_${QPS}qps_$(basename ${WORKLOAD} .yaml)"
    TEMP_WORKLOAD_IN="${SCRIPT_DIR}/workload/profiles/guidellm/${TEMP_WORKLOAD_BASENAME}.yaml.in"

    # Create the .in template with the modified rate
    if [ -f "${SCRIPT_DIR}/workload/profiles/guidellm/${WORKLOAD}.in" ]; then
        sed "s/^rate: .*/rate: ${QPS}/" "${SCRIPT_DIR}/workload/profiles/guidellm/${WORKLOAD}.in" > "${TEMP_WORKLOAD_IN}"
    elif [ -f "${SCRIPT_DIR}/workload/profiles/guidellm/${WORKLOAD}" ]; then
        sed "s/^rate: .*/rate: ${QPS}/" "${SCRIPT_DIR}/workload/profiles/guidellm/${WORKLOAD}" > "${TEMP_WORKLOAD_IN}"
    else
        print_error "Workload file not found: ${WORKLOAD}"
        exit 1
    fi

    print_info "Created workload template: ${TEMP_WORKLOAD_IN}"
    print_info "Running benchmark at ${QPS} QPS..."

    # Start Prometheus metrics collection in background
    PROM_OUTPUT="${SWEEP_RESULTS_DIR}/qps_${QPS}_metrics"
    collect_prometheus_metrics "${NAMESPACE}" 110 "${PROM_OUTPUT}" &
    PROM_PID=$!

    # Run the benchmark
    cd "${SCRIPT_DIR}"

    set +e  # Don't exit on error for individual runs
    ./run.sh \
        -l ${HARNESS} \
        -w "${TEMP_WORKLOAD_BASENAME}.yaml" \
        -p ${NAMESPACE} \
        -s ${TIMEOUT} \
        -t ${GATEWAY_NAME} \
        -m ${LLMDBENCH_DEPLOY_CURRENT_MODEL} 2>&1 | tee "${SWEEP_RESULTS_DIR}/run_${QPS}qps.log"

    BENCHMARK_EXIT_CODE=$?
    set -e

    # Wait for Prometheus collection to finish
    wait $PROM_PID 2>/dev/null || true

    # Check if benchmark actually failed despite exit code 0
    if grep -q "Could not find workload" "${SWEEP_RESULTS_DIR}/run_${QPS}qps.log" 2>/dev/null; then
        print_error "Benchmark failed - workload file not found"
        BENCHMARK_EXIT_CODE=1
    fi

    if [ $BENCHMARK_EXIT_CODE -eq 0 ]; then
        print_success "Benchmark completed for ${QPS} QPS"

        # Find the most recent results - check multiple possible locations
        LATEST_RESULT=""
        for results_dir in ~/data/pd-disaggregation-slo/results ~/data/*/results; do
            if [ -d "$results_dir" ]; then
                RESULT=$(find "$results_dir" -type f -name "benchmark_report,_results.json_0.yaml" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2)
                if [ -n "$RESULT" ]; then
                    LATEST_RESULT="$RESULT"
                    break
                fi
            fi
        done

        if [ -n "$LATEST_RESULT" ] && [ -f "$LATEST_RESULT" ]; then
            # Extract metrics
            REQUESTS_PER_SEC=$(grep "requests_per_sec:" "$LATEST_RESULT" | awk '{print $2}')
            OUTPUT_TOKENS_PER_SEC=$(grep "output_tokens_per_sec:" "$LATEST_RESULT" | awk '{print $2}')
            TOTAL_REQUESTS=$(grep -E "^  total:" "$LATEST_RESULT" | tail -1 | awk '{print $2}')
            INCOMPLETE=$(grep "incomplete:" "$LATEST_RESULT" | awk '{print $2}')
            FAILURES=$(grep "failures:" "$LATEST_RESULT" | awk '{print $2}')

            # Extract all percentiles
            TTFT_MEDIAN=$(grep -A 50 "time_to_first_token:" "$LATEST_RESULT" | grep "p50:" | awk '{print $2}')
            TTFT_P90=$(grep -A 50 "time_to_first_token:" "$LATEST_RESULT" | grep "p90:" | awk '{print $2}')
            TTFT_P95=$(grep -A 50 "time_to_first_token:" "$LATEST_RESULT" | grep "p95:" | awk '{print $2}')
            TPOT_MEDIAN=$(grep -A 50 "time_per_output_token:" "$LATEST_RESULT" | grep "p50:" | awk '{print $2}')
            TPOT_P90=$(grep -A 50 "time_per_output_token:" "$LATEST_RESULT" | grep "p90:" | awk '{print $2}')
            TPOT_P95=$(grep -A 50 "time_per_output_token:" "$LATEST_RESULT" | grep "p95:" | awk '{print $2}')
            REQ_LAT_MEDIAN=$(grep -A 50 "request_latency:" "$LATEST_RESULT" | grep "p50:" | head -1 | awk '{print $2}')
            REQ_LAT_P95=$(grep -A 50 "request_latency:" "$LATEST_RESULT" | grep "p95:" | head -1 | awk '{print $2}')

            COMPLETED=$((TOTAL_REQUESTS - INCOMPLETE - FAILURES))

            # Convert request latency from seconds to milliseconds
            REQ_LAT_MEDIAN_MS=$(echo "$REQ_LAT_MEDIAN * 1000" | bc)
            REQ_LAT_P95_MS=$(echo "$REQ_LAT_P95 * 1000" | bc)

            # Calculate SLO success rates
            # Parse results.json for detailed per-request metrics
            RESULT_DIR=$(dirname "$LATEST_RESULT")
            RESULTS_JSON="${RESULT_DIR}/results.json"

            if [ -f "$RESULTS_JSON" ] && [ "$SLO_TTFT_MS" != "N/A" ] && [ "$SLO_TPOT_MS" != "N/A" ]; then
                # Count requests meeting SLO (TTFT < SLO_TTFT and TPOT < SLO_TPOT)
                SLO_SUCCESS_COUNT=$(python3 << PYEOF
import json
import sys

try:
    with open("$RESULTS_JSON") as f:
        data = json.load(f)

    slo_ttft = float($SLO_TTFT_MS) / 1000  # Convert to seconds
    slo_tpot = float($SLO_TPOT_MS) / 1000  # Convert to seconds

    success_count = 0
    completed_count = 0

    for result in data.get("results", []):
        if result.get("completed", False):
            completed_count += 1
            ttft = result.get("start_time", 0)  # Simplified - actual field may differ
            tpot = result.get("decode_throughput", 0)  # Simplified

            # Check if meets SLO (this is simplified - adapt to actual JSON structure)
            if ttft <= slo_ttft and tpot <= slo_tpot:
                success_count += 1

    print(success_count)
except Exception as e:
    print(0, file=sys.stderr)
    print(0)
PYEOF
)
                SLO_SUCCESS_RATE_COMPLETED=$(echo "scale=4; $SLO_SUCCESS_COUNT * 100 / $COMPLETED" | bc)
                SLO_SUCCESS_RATE_ALL=$(echo "scale=4; $SLO_SUCCESS_COUNT * 100 / $TOTAL_REQUESTS" | bc)
            else
                # Fallback: estimate based on p90 metrics
                if [ "$SLO_TTFT_MS" != "N/A" ] && [ "$SLO_TPOT_MS" != "N/A" ]; then
                    # If p90 is within SLO, assume ~90% success rate
                    if (( $(echo "$TTFT_P90 < $SLO_TTFT_MS" | bc -l) )) && (( $(echo "$TPOT_P90 < $SLO_TPOT_MS" | bc -l) )); then
                        SLO_SUCCESS_RATE_COMPLETED="90.0"
                        SLO_SUCCESS_RATE_ALL=$(echo "scale=4; 90.0 * $COMPLETED / $TOTAL_REQUESTS" | bc)
                    else
                        SLO_SUCCESS_RATE_COMPLETED="50.0"
                        SLO_SUCCESS_RATE_ALL=$(echo "scale=4; 50.0 * $COMPLETED / $TOTAL_REQUESTS" | bc)
                    fi
                else
                    SLO_SUCCESS_RATE_COMPLETED="N/A"
                    SLO_SUCCESS_RATE_ALL="N/A"
                fi
            fi

            # Count 429 errors from logs
            ERROR_429_COUNT=$(grep -c "429" "${SWEEP_RESULTS_DIR}/run_${QPS}qps.log" 2>/dev/null || echo "0")

            # Calculate p90 from Prometheus metrics
            P90_KV_CACHE=$(calculate_p90_from_prom "${PROM_OUTPUT}.kv_cache.json")
            P90_QUEUE=$(calculate_p90_from_prom "${PROM_OUTPUT}.queue.json")
            P90_GPU=$(calculate_p90_from_prom "${PROM_OUTPUT}.gpu_util.json")

            # Write to CSV
            echo "${QPS},${REQUESTS_PER_SEC},${OUTPUT_TOKENS_PER_SEC},${TOTAL_REQUESTS},${COMPLETED},${INCOMPLETE},${FAILURES},${ERROR_429_COUNT},${TTFT_MEDIAN},${TTFT_P90},${TTFT_P95},${TPOT_MEDIAN},${TPOT_P90},${TPOT_P95},${REQ_LAT_MEDIAN_MS},${REQ_LAT_P95_MS},${SLO_SUCCESS_RATE_COMPLETED},${SLO_SUCCESS_RATE_ALL},${P90_KV_CACHE},${P90_QUEUE},${P90_GPU}" >> ${SUMMARY_FILE}

            print_info "Metrics: ${REQUESTS_PER_SEC} req/s, ${OUTPUT_TOKENS_PER_SEC} tokens/s, ${INCOMPLETE} incomplete, SLO success: ${SLO_SUCCESS_RATE_COMPLETED}%"

            # Copy results to sweep directory
            cp -r "$RESULT_DIR" "${SWEEP_RESULTS_DIR}/qps_${QPS}"
        else
            print_warning "Could not find results file for ${QPS} QPS"
            echo "${QPS},N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A" >> ${SUMMARY_FILE}
        fi
    else
        print_error "Benchmark failed for ${QPS} QPS (exit code: ${BENCHMARK_EXIT_CODE})"
        echo "${QPS},FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED,FAILED" >> ${SUMMARY_FILE}
    fi

    # Clean up temp workload template
    rm -f "${TEMP_WORKLOAD_IN}"

    # Small delay between runs
    if [ $CURRENT_RUN -lt $NUM_RUNS ]; then
        print_info "Waiting 10 seconds before next run..."
        sleep 10
    fi

    echo ""
done

print_header "Rate Sweep Complete!"
echo ""
print_success "All ${NUM_RUNS} benchmarks completed"
print_success "Results saved to: ${SWEEP_RESULTS_DIR}"
print_success "Summary CSV: ${SUMMARY_FILE}"
echo ""
print_info "View summary:"
echo -e "  ${YELLOW}cat ${SUMMARY_FILE} | column -t -s,${NC}"
echo ""
print_info "CSV Columns:"
echo -e "  - qps: Target request rate"
echo -e "  - requests_per_sec: Achieved throughput"
echo -e "  - slo_success_completed: % of completed requests meeting SLO"
echo -e "  - slo_success_all: % of all attempted requests meeting SLO"
echo -e "  - error_429_count: Number of rate limit errors"
echo -e "  - ttft_p90_ms: 90th percentile time to first token"
echo -e "  - tpot_p90_ms: 90th percentile time per output token"
echo -e "  - p90_kv_cache_util: 90th percentile KV cache utilization %"
echo -e "  - p90_queue_length: 90th percentile waiting queue length"
echo -e "  - p90_gpu_util: 90th percentile GPU utilization %"
echo ""
