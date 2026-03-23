#!/bin/bash
# Quick Start Script for PD Disaggregation with SLO Routing Benchmark
# This script automates the entire benchmarking workflow
# Usage: ./run-pd-slo-benchmark.sh [workload_name.yaml]

set -e

# Configuration
NAMESPACE="${NAMESPACE:-rsaini-dev}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCENARIO="${SCRIPT_DIR}/scenarios/guides/pd-disaggregation-slo.sh"
HARNESS="guidellm"
WORKLOAD="${1:-rate_sweep_slo.yaml}"  # Accept workload as first argument, default to rate_sweep_slo.yaml
TIMEOUT=7200  # 2 hours

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
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

# Main execution
print_header "PD Disaggregation SLO Benchmark - Quick Start"

# Check prerequisites
print_header "Step 1: Checking Prerequisites"

if ! kubectl cluster-info &>/dev/null; then
    print_error "kubectl not configured or cluster not accessible"
    exit 1
fi
print_success "Kubernetes cluster accessible"

if ! kubectl get namespace ${NAMESPACE} &>/dev/null; then
    print_warning "Namespace ${NAMESPACE} not found, creating it..."
    kubectl create namespace ${NAMESPACE}
fi
print_success "Namespace ${NAMESPACE} ready"

if ! kubectl get secret -n ${NAMESPACE} llm-d-hf-token &>/dev/null; then
    print_error "HuggingFace token secret not found in namespace ${NAMESPACE}"
    echo -e "  Create it with:"
    echo -e "  kubectl create secret generic llm-d-hf-token --from-literal=HF_TOKEN=<your-token> -n ${NAMESPACE}"
    exit 1
fi
print_success "HuggingFace token secret found"

# Check if deployment exists
print_header "Step 2: Checking Deployment"

PREFILL_PODS=$(kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=prefill --no-headers 2>/dev/null | wc -l)
DECODE_PODS=$(kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=decode --no-headers 2>/dev/null | wc -l)

if [ "$DECODE_PODS" -eq 0 ]; then
    print_warning "No decode pods found"
    echo -e "  Current state: ${PREFILL_PODS} prefill pods, ${DECODE_PODS} decode pods"

    read -p "Do you want to deploy the stack now? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deploying stack with standup.sh..."
        ./setup/standup.sh -c ${SCENARIO} -p ${NAMESPACE}
        print_success "Stack deployed"
    else
        print_error "Deployment required. Please deploy the stack first."
        echo -e "  You can deploy with:"
        echo -e "  cd llm-d-benchmark && ./setup/standup.sh -c ${SCENARIO} -p ${NAMESPACE}"
        exit 1
    fi
else
    if [ "$PREFILL_PODS" -gt 0 ]; then
        print_success "Found ${PREFILL_PODS} prefill pods and ${DECODE_PODS} decode pods (P/D mode)"
    else
        print_success "Found ${DECODE_PODS} decode pods (decode-only mode)"
    fi

    # Check if they're running
    RUNNING_PODS=$(kubectl get pods -n ${NAMESPACE} -l llm-d.ai/inferenceServing=true --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    TOTAL_PODS=$((PREFILL_PODS + DECODE_PODS))

    if [ "$RUNNING_PODS" -ne "$TOTAL_PODS" ]; then
        print_warning "Some pods are not running (${RUNNING_PODS}/${TOTAL_PODS})"
        echo -e "  Waiting for pods to be ready..."
        kubectl wait --for=condition=ready pod -l llm-d.ai/inferenceServing=true -n ${NAMESPACE} --timeout=600s || true
    fi
    print_success "All pods are running"
fi

# Check SLO components
print_info "Checking SLO components..."
if kubectl get deployment -n ${NAMESPACE} -l app=latency-training &>/dev/null; then
    print_success "SLO latency predictor found"
else
    print_warning "SLO latency predictor not found - routing may not be SLO-aware"
    echo -e "  To enable SLO routing, upgrade GAIE:"
    echo -e "  helm upgrade gaie-pd llm-d/inferencepool -f gaie-pd/values-slo.yaml -n ${NAMESPACE}"
fi

# Get gateway endpoint
print_header "Step 3: Getting Gateway Endpoint"

# Try multiple methods to find the gateway service
GATEWAY_SVC=$(kubectl get svc -n ${NAMESPACE} -l app.kubernetes.io/component=gateway -o name 2>/dev/null | head -1)

if [ -z "$GATEWAY_SVC" ]; then
    # Fallback: look for service with 'gateway' in name
    GATEWAY_SVC=$(kubectl get svc -n ${NAMESPACE} -o name 2>/dev/null | grep -i gateway | grep -i istio | head -1)
fi

if [ -z "$GATEWAY_SVC" ]; then
    # Fallback: try to get from Gateway API resource
    GATEWAY_NAME=$(kubectl get gateway -n ${NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$GATEWAY_NAME" ]; then
        # Common pattern: gateway-name-istio for service name
        GATEWAY_SVC="service/${GATEWAY_NAME}-istio"
    fi
fi

if [ -z "$GATEWAY_SVC" ]; then
    print_error "Gateway service not found"
    echo -e "  Available services:"
    kubectl get svc -n ${NAMESPACE}
    exit 1
fi

print_success "Found gateway service: ${GATEWAY_SVC}"

GATEWAY_NAME=$(echo ${GATEWAY_SVC} | sed 's|service/||')
GATEWAY_TYPE=$(kubectl get svc ${GATEWAY_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.type}')
print_info "Gateway type: ${GATEWAY_TYPE}"

if [ "$GATEWAY_TYPE" = "LoadBalancer" ]; then
    GATEWAY_IP=$(kubectl get svc ${GATEWAY_NAME} -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [ -z "$GATEWAY_IP" ]; then
        GATEWAY_IP=$(kubectl get svc ${GATEWAY_NAME} -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    fi
    if [ -n "$GATEWAY_IP" ]; then
        GATEWAY_URL="http://${GATEWAY_IP}/v1"
        print_success "Gateway accessible externally at ${GATEWAY_URL}"
    else
        print_warning "LoadBalancer IP not yet assigned, will use internal service"
        GATEWAY_TYPE="ClusterIP"
    fi
fi

if [ "$GATEWAY_TYPE" = "ClusterIP" ] || [ -z "$GATEWAY_IP" ]; then
    GATEWAY_URL="http://${GATEWAY_NAME}.${NAMESPACE}.svc.cluster.local"
    print_info "Gateway will be accessed internally at ${GATEWAY_URL}"
fi

# Test connectivity
print_info "Testing gateway connectivity..."
kubectl run -n ${NAMESPACE} --rm -i --restart=Never --image=curlimages/curl test-curl -- \
    curl -s -m 5 http://${GATEWAY_NAME}.${NAMESPACE}.svc.cluster.local/v1/models 2>/dev/null && \
    print_success "Gateway responding to health checks" || \
    print_warning "Gateway connectivity check timed out (this may be normal during startup)"

# Run benchmark
print_header "Step 4: Running Benchmark"

print_info "Configuration:"
echo -e "  Namespace:    ${NAMESPACE}"
echo -e "  Scenario:     ${SCENARIO}"
echo -e "  Harness:      ${HARNESS}"
echo -e "  Workload:     ${WORKLOAD}"
echo -e "  Timeout:      ${TIMEOUT}s (~$(($TIMEOUT / 60)) minutes)"
echo ""

# Start Prometheus metrics collection in background (if available)
if kubectl get namespace monitoring &>/dev/null; then
    print_info "Starting Prometheus metrics collection..."

    cat > /tmp/collect_metrics.sh << 'METRICSCRIPT'
#!/bin/bash
NAMESPACE=$1
DURATION=$2
kubectl port-forward -n monitoring svc/prometheus-k8s 9090:9090 &
PF_PID=$!
sleep 5
START=$(date +%s)
END=$((START + DURATION))
curl -G "http://localhost:9090/api/v1/query_range" \
  --data-urlencode "query=vllm:kv_cache_usage_perc{namespace=\"${NAMESPACE}\"}" \
  --data-urlencode "start=${START}" --data-urlencode "end=${END}" \
  --data-urlencode "step=15s" > ~/kv_cache_metrics.json 2>/dev/null
curl -G "http://localhost:9090/api/v1/query_range" \
  --data-urlencode "query=vllm:num_requests_waiting{namespace=\"${NAMESPACE}\"}" \
  --data-urlencode "start=${START}" --data-urlencode "end=${END}" \
  --data-urlencode "step=15s" > ~/queue_metrics.json 2>/dev/null
kill $PF_PID 2>/dev/null
METRICSCRIPT

    chmod +x /tmp/collect_metrics.sh
    /tmp/collect_metrics.sh ${NAMESPACE} ${TIMEOUT} &
    METRICS_PID=$!
    print_info "Metrics collection started (PID: ${METRICS_PID})"
fi

# Run the actual benchmark
print_info "Launching benchmark..."
echo ""

# Change to benchmark directory to ensure relative paths work
cd "${SCRIPT_DIR}"

# Export variables to fix auto-detection while keeping validation enabled
# run.sh looks for LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME and constructs the URL from it
# We need to set the FULL FQDN here to prevent run.sh from appending and getting "null.namespace.svc"
export LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME="${GATEWAY_NAME}.${NAMESPACE}.svc.cluster.local"
export LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT="80"
export LLMDBENCH_VLLM_MODELSERVICE_SERVICE_NAME="${GATEWAY_NAME}"
export LLMDBENCH_DEPLOY_CURRENT_MODEL="RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic"

# Source the scenario file to ensure all variables are loaded
source ${SCENARIO}

# Construct the full URL
export LLMDBENCH_HARNESS_STACK_ENDPOINT_URL="http://${LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME}:${LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT}"

print_info "Configuration:"
print_info "  Endpoint Name (FQDN): ${LLMDBENCH_HARNESS_STACK_ENDPOINT_NAME}"
print_info "  Endpoint Port: ${LLMDBENCH_HARNESS_STACK_ENDPOINT_PORT}"
print_info "  Full URL: ${LLMDBENCH_HARNESS_STACK_ENDPOINT_URL}"
print_info "  Model: ${LLMDBENCH_DEPLOY_CURRENT_MODEL}"
print_info "  Workload: ${WORKLOAD}"
print_info "  Note: Model auto-detection will be bypassed (already deployed)"

# Set GUIDELLM backend kwargs if not already set (will be propagated to harness pods)
if [[ -z "$LLMDBENCH_GUIDELLM_BACKEND_KWARGS" ]]; then
    export LLMDBENCH_GUIDELLM_BACKEND_KWARGS='{\"extra_headers\":{\"x-slo-ttft-ms\":\"800\",\"x-slo-tpot-ms\":\"18\"}}'
fi

./run.sh \
    -l ${HARNESS} \
    -w ${WORKLOAD} \
    -p ${NAMESPACE} \
    -s ${TIMEOUT} \
    -t ${GATEWAY_NAME} \
    -m ${LLMDBENCH_DEPLOY_CURRENT_MODEL} \
    -g "LLMDBENCH_RUN_EXPERIMENT,LLMDBENCH_GUIDELLM_BACKEND_KWARGS"

BENCHMARK_EXIT_CODE=$?

# Wait for metrics collection to finish
if [ -n "$METRICS_PID" ]; then
    wait $METRICS_PID 2>/dev/null || true
fi

if [ $BENCHMARK_EXIT_CODE -eq 0 ]; then
    print_header "Step 5: Benchmark Complete!"

    # Find results directory
    RESULTS_DIR=$(find ~/data/pd-disaggregation-slo* -type d -name "*guidellm*" 2>/dev/null | head -1)
    if [ -z "$RESULTS_DIR" ]; then
        RESULTS_DIR="~/data/pd-disaggregation-slo"
    fi

    print_success "Results saved to: ${RESULTS_DIR}"

    if [ -f ~/kv_cache_metrics.json ]; then
        print_success "Prometheus metrics saved to: ~/kv_cache_metrics.json and ~/queue_metrics.json"
    fi

    echo ""
    print_header "Next Steps"
    echo -e "1. Analyze results with Jupyter notebook:"
    echo -e "   ${YELLOW}cd analysis && jupyter lab analysis.ipynb${NC}"
    echo ""
    echo -e "2. View detailed guide:"
    echo -e "   ${YELLOW}less PD_DISAGGREGATION_SLO_BENCHMARK_GUIDE.md${NC}"
    echo ""
    echo -e "3. Generate plots (see guide for Python code examples)"
    echo ""

else
    print_error "Benchmark failed with exit code ${BENCHMARK_EXIT_CODE}"
    echo -e "Check logs with:"
    echo -e "  kubectl logs -n ${NAMESPACE} deployment/llmdbench-guidellm-launcher"
    exit $BENCHMARK_EXIT_CODE
fi
