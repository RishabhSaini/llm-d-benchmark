# P/D DISAGGREGATION WITH SLO ROUTING - BENCHMARK SCENARIO
# Based on pd-disaggregation.sh but configured for SLO-based routing
# This scenario enables latency prediction and SLO-aware scheduling

# IMPORTANT NOTE
# All parameters not defined here or exported externally will be the default values found in setup/env.sh

# Model parameters
export LLMDBENCH_DEPLOY_MODEL_LIST="RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic"

# PVC parameters
export LLMDBENCH_VLLM_COMMON_PVC_MODEL_CACHE_SIZE=1Ti

# Routing configuration - ENABLE SLO ROUTING
export LLMDBENCH_VLLM_MODELSERVICE_INFERENCE_MODEL=true
export LLMDBENCH_VLLM_MODELSERVICE_GAIE_VALUES_FILE="values-slo.yaml"  # Use SLO values instead of default

# Gateway endpoint - set explicitly to avoid auto-detection issues
export LLMDBENCH_HARNESS_STACK_ENDPOINT_URL="http://infra-pd-inference-gateway-istio.llm-d-pd.svc.cluster.local"

# Common parameters across prefill and decode pods
export LLMDBENCH_VLLM_COMMON_MAX_MODEL_LEN=4096  # Reduced to fit in memory
export LLMDBENCH_VLLM_COMMON_BLOCK_SIZE=128

export LLMDBENCH_VLLM_COMMON_ENVVARS_TO_YAML=$(mktemp)
cat << EOF > $LLMDBENCH_VLLM_COMMON_ENVVARS_TO_YAML
- name: UCX_TLS
  value: "rc,sm,cuda_ipc,cuda_copy,tcp"
- name: UCX_SOCKADDR_TLS_PRIORITY
  value: "tcp"
- name: VLLM_NIXL_SIDE_CHANNEL_PORT
  value: "REPLACE_ENV_LLMDBENCH_VLLM_COMMON_NIXL_SIDE_CHANNEL_PORT"
- name: VLLM_NIXL_SIDE_CHANNEL_HOST
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: VLLM_LOGGING_LEVEL
  value: INFO
- name: VLLM_ALLOW_LONG_MAX_MODEL_LEN
  value: "1"
EOF

# Prefill parameters
export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_TENSOR_PARALLELISM=1
export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_REPLICAS=4
export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_CPU_NR=8
export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_CPU_MEM=64Gi
export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_ACCELERATOR_MEM_UTIL=0.90

# Network resources (uncomment based on your setup)
# export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_NETWORK_RESOURCE=rdma/ib
# export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_NETWORK_NR=1

export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_MODEL_COMMAND=custom
export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_PREPROCESS="python3 /setup/preprocess/set_llmdbench_environment.py; source \$HOME/llmdbench_env.sh"
export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_EXTRA_ARGS=$(mktemp)
cat << EOF > $LLMDBENCH_VLLM_MODELSERVICE_PREFILL_EXTRA_ARGS
REPLACE_ENV_LLMDBENCH_VLLM_MODELSERVICE_PREFILL_PREPROCESS; \
vllm serve /model-cache/models/REPLACE_ENV_LLMDBENCH_DEPLOY_CURRENT_MODEL \
--host 0.0.0.0 \
--served-model-name REPLACE_ENV_LLMDBENCH_DEPLOY_CURRENT_MODEL \
--port REPLACE_ENV_LLMDBENCH_VLLM_MODELSERVICE_PREFILL_INFERENCE_PORT \
--block-size REPLACE_ENV_LLMDBENCH_VLLM_COMMON_BLOCK_SIZE \
--max-model-len REPLACE_ENV_LLMDBENCH_VLLM_COMMON_MAX_MODEL_LEN \
--tensor-parallel-size REPLACE_ENV_LLMDBENCH_VLLM_MODELSERVICE_PREFILL_TENSOR_PARALLELISM \
--gpu-memory-utilization REPLACE_ENV_LLMDBENCH_VLLM_MODELSERVICE_PREFILL_ACCELERATOR_MEM_UTIL \
--kv-transfer-config "{\"kv_connector\":\"NixlConnector\",\"kv_role\":\"kv_both\"}" \
--disable-log-requests \
--disable-uvicorn-access-log \
--no-enable-prefix-caching
EOF

export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_EXTRA_VOLUME_MOUNTS=$(mktemp)
cat << EOF > ${LLMDBENCH_VLLM_MODELSERVICE_PREFILL_EXTRA_VOLUME_MOUNTS}
- name: dshm
  mountPath: /dev/shm
- name: preprocesses
  mountPath: /setup/preprocess
EOF

export LLMDBENCH_VLLM_MODELSERVICE_PREFILL_EXTRA_VOLUMES=$(mktemp)
cat << EOF > ${LLMDBENCH_VLLM_MODELSERVICE_PREFILL_EXTRA_VOLUMES}
- name: preprocesses
  configMap:
    defaultMode: 320
    name: llm-d-benchmark-preprocesses
- name: dshm
  emptyDir:
    medium: Memory
    sizeLimit: REPLACE_ENV_LLMDBENCH_VLLM_COMMON_SHM_MEM
EOF

# Decode parameters
export LLMDBENCH_VLLM_MODELSERVICE_DECODE_TENSOR_PARALLELISM=4
export LLMDBENCH_VLLM_MODELSERVICE_DECODE_REPLICAS=1
export LLMDBENCH_VLLM_MODELSERVICE_DECODE_CPU_NR=16
export LLMDBENCH_VLLM_MODELSERVICE_DECODE_CPU_MEM=64Gi
export LLMDBENCH_VLLM_MODELSERVICE_DECODE_ACCELERATOR_MEM_UTIL=0.90

# Network resources (uncomment based on your setup)
# export LLMDBENCH_VLLM_MODELSERVICE_DECODE_NETWORK_RESOURCE=rdma/ib
# export LLMDBENCH_VLLM_MODELSERVICE_DECODE_NETWORK_NR=1

export LLMDBENCH_VLLM_MODELSERVICE_DECODE_MODEL_COMMAND=custom
export LLMDBENCH_VLLM_MODELSERVICE_DECODE_PREPROCESS="python3 /setup/preprocess/set_llmdbench_environment.py; source \$HOME/llmdbench_env.sh"
export LLMDBENCH_VLLM_MODELSERVICE_DECODE_EXTRA_ARGS=$(mktemp)
cat << EOF > $LLMDBENCH_VLLM_MODELSERVICE_DECODE_EXTRA_ARGS
REPLACE_ENV_LLMDBENCH_VLLM_MODELSERVICE_DECODE_PREPROCESS; \
vllm serve /model-cache/models/REPLACE_ENV_LLMDBENCH_DEPLOY_CURRENT_MODEL \
--host 0.0.0.0 \
--served-model-name REPLACE_ENV_LLMDBENCH_DEPLOY_CURRENT_MODEL \
--port REPLACE_ENV_LLMDBENCH_VLLM_COMMON_METRICS_PORT \
--block-size REPLACE_ENV_LLMDBENCH_VLLM_COMMON_BLOCK_SIZE \
--max-model-len REPLACE_ENV_LLMDBENCH_VLLM_COMMON_MAX_MODEL_LEN \
--tensor-parallel-size REPLACE_ENV_LLMDBENCH_VLLM_MODELSERVICE_DECODE_TENSOR_PARALLELISM \
--gpu-memory-utilization REPLACE_ENV_LLMDBENCH_VLLM_MODELSERVICE_DECODE_ACCELERATOR_MEM_UTIL \
--kv-transfer-config "{\"kv_connector\":\"NixlConnector\",\"kv_role\":\"kv_both\"}" \
--disable-log-requests \
--disable-uvicorn-access-log \
--no-enable-prefix-caching
EOF

export LLMDBENCH_VLLM_MODELSERVICE_DECODE_EXTRA_VOLUME_MOUNTS=$(mktemp)
cat << EOF > ${LLMDBENCH_VLLM_MODELSERVICE_DECODE_EXTRA_VOLUME_MOUNTS}
- name: dshm
  mountPath: /dev/shm
- name: preprocesses
  mountPath: /setup/preprocess
EOF

export LLMDBENCH_VLLM_MODELSERVICE_DECODE_EXTRA_VOLUMES=$(mktemp)
cat << EOF > ${LLMDBENCH_VLLM_MODELSERVICE_DECODE_EXTRA_VOLUMES}
- name: preprocesses
  configMap:
    defaultMode: 320
    name: llm-d-benchmark-preprocesses
- name: dshm
  emptyDir:
    medium: Memory
    sizeLimit: REPLACE_ENV_LLMDBENCH_VLLM_COMMON_SHM_MEM
EOF

# Timeout for benchmark operations
export LLMDBENCH_CONTROL_WAIT_TIMEOUT=900000
export LLMDBENCH_HARNESS_WAIT_TIMEOUT=900000

# Workload parameters - USE GUIDELLM
export LLMDBENCH_HARNESS_NAME=guidellm
export LLMDBENCH_HARNESS_EXPERIMENT_PROFILE=rate_sweep_slo.yaml

# Local directory to copy benchmark runtime files and results
export LLMDBENCH_CONTROL_WORK_DIR=~/data/pd-disaggregation-slo
