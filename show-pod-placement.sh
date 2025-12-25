#!/bin/bash
# Script to show pod placement across GPU nodes
# Usage: ./show-pod-placement.sh [namespace]

NAMESPACE="${1:-llm-d-pd}"

# Color codes
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Pod Placement ===${NC}"
echo ""

# H200 nodes
h200_nodes="g11e7fc g12bfa0 g12dd76 g135118"
h100_nodes="g734cf4 g83e7f8 g842650 g85323e"

# Function to get pod counts for a node
get_pod_counts() {
    local node=$1
    local namespace=$2

    decode_count=$(kubectl get pods -n $namespace -l llm-d.ai/role=decode \
        --field-selector spec.nodeName=$node --no-headers 2>/dev/null | wc -l)

    prefill_count=$(kubectl get pods -n $namespace -l llm-d.ai/role=prefill \
        --field-selector spec.nodeName=$node --no-headers 2>/dev/null | wc -l)

    # Decode uses TP=4, prefill uses TP=1
    gpus_used=$((decode_count * 4 + prefill_count))

    echo "$decode_count $prefill_count $gpus_used"
}

# Display H200 nodes
echo -e "${GREEN}H200 Nodes (143GB VRAM per GPU):${NC}"
h200_total_decode=0
h200_total_prefill=0
h200_total_gpus=0

for node in $h200_nodes; do
    read decode prefill gpus <<< $(get_pod_counts $node $NAMESPACE)
    h200_total_decode=$((h200_total_decode + decode))
    h200_total_prefill=$((h200_total_prefill + prefill))
    h200_total_gpus=$((h200_total_gpus + gpus))

    printf "  - %s: %d decode + %d prefill = ${YELLOW}%d/8 GPUs used${NC}\n" \
        "$node" $decode $prefill $gpus
done

echo ""

# Display H100 nodes
echo -e "${GREEN}H100 NVLink Nodes (81GB VRAM per GPU):${NC}"
h100_total_decode=0
h100_total_prefill=0
h100_total_gpus=0

for node in $h100_nodes; do
    read decode prefill gpus <<< $(get_pod_counts $node $NAMESPACE)
    h100_total_decode=$((h100_total_decode + decode))
    h100_total_prefill=$((h100_total_prefill + prefill))
    h100_total_gpus=$((h100_total_gpus + gpus))

    printf "  - %s: %d decode + %d prefill = ${YELLOW}%d/8 GPUs used${NC}\n" \
        "$node" $decode $prefill $gpus
done

echo ""
echo -e "${BLUE}=== Summary ===${NC}"
echo ""
printf "H200 Nodes:      %d decode pods + %d prefill pods = ${YELLOW}%d/32 GPUs${NC}\n" \
    $h200_total_decode $h200_total_prefill $h200_total_gpus
printf "H100 Nodes:      %d decode pods + %d prefill pods = ${YELLOW}%d/32 GPUs${NC}\n" \
    $h100_total_decode $h100_total_prefill $h100_total_gpus

echo ""
total_decode=$((h200_total_decode + h100_total_decode))
total_prefill=$((h200_total_prefill + h100_total_prefill))
total_gpus=$((h200_total_gpus + h100_total_gpus))

printf "Total Cluster:   %d decode pods + %d prefill pods = ${GREEN}%d/64 GPUs${NC}\n" \
    $total_decode $total_prefill $total_gpus

echo ""
printf "GPU Utilization: ${GREEN}%.1f%%${NC}\n" $(echo "scale=1; $total_gpus * 100 / 64" | bc)
