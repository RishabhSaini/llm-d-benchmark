#!/usr/bin/env bash

echo Using experiment result dir: "$LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR"
mkdir -p "$LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR"
pushd "$LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR" > /dev/null  2>&1

# Extract SLO headers from YAML if present
YAML_PATH="${LLMDBENCH_RUN_WORKSPACE_DIR}/profiles/guidellm/${LLMDBENCH_RUN_EXPERIMENT_HARNESS_WORKLOAD_NAME}"

# Extract SLO headers from YAML
TTFT_SLO=$(grep "x-slo-ttft-ms:" "$YAML_PATH" 2>/dev/null | awk '{print $2}' | tr -d '"')
TPOT_SLO=$(grep "x-slo-tpot-ms:" "$YAML_PATH" 2>/dev/null | awk '{print $2}' | tr -d '"')

# Set environment variables for the wrapper to inject
if [[ -n "$TTFT_SLO" ]]; then
  export SLO_TTFT_MS="$TTFT_SLO"
fi
if [[ -n "$TPOT_SLO" ]]; then
  export SLO_TPOT_MS="$TPOT_SLO"
fi

if [[ -n "$TTFT_SLO" ]] || [[ -n "$TPOT_SLO" ]]; then
  echo "Found SLO headers in YAML: TTFT=${TTFT_SLO}ms, TPOT=${TPOT_SLO}ms"
  echo "Using SLO wrapper to inject headers into requests"
fi

# Record start time before running benchmark
start=$(date +%s.%N)

# Use the wrapper script that will inject SLO headers via monkey-patching
python3 /usr/local/bin/slo_header_injector.py benchmark --scenario "${YAML_PATH}" --output-path "${LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR}/results.json" --disable-progress > >(tee -a $LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR/stdout.log) 2> >(tee -a $LLMDBENCH_RUN_EXPERIMENT_RESULTS_DIR/stderr.log >&2)
export LLMDBENCH_RUN_EXPERIMENT_HARNESS_RC=$?
stop=$(date +%s.%N)

export LLMDBENCH_HARNESS_START=$(date -d "@${start}" --iso-8601=seconds)
export LLMDBENCH_HARNESS_STOP=$(date -d "@${stop}" --iso-8601=seconds)
export LLMDBENCH_HARNESS_DELTA=PT$(echo "$stop - $start" | bc)S
export LLMDBENCH_HARNESS_VERSION=$(guidellm --version)

# If benchmark harness returned with an error, exit here
if [[ $LLMDBENCH_RUN_EXPERIMENT_HARNESS_RC -ne 0 ]]; then
  echo "Harness returned with error $LLMDBENCH_RUN_EXPERIMENT_HARNESS_RC"
  exit $LLMDBENCH_RUN_EXPERIMENT_HARNESS_RC
fi
echo "Harness completed successfully."

exit $LLMDBENCH_RUN_EXPERIMENT_HARNESS_RC
