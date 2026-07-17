#!/bin/bash

# Deploy script for iDO-Files File Server
# This script:
# 1. SCP project to remote server
# 2. Build and push Docker image
# 3. Restart Kubernetes deployment

set -e  # Exit on error

# Load configuration from env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env.local"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}



# Step 1: Rsync project to remote server
step1_rsync() {
    echo_info "Step 1: Syncing project to remote server..."
    
    # Create remote directory
    echo_info "Creating remote directory..."
    ssh -o StrictHostKeyChecking=no -p "${REMOTE_PORT}" \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        "mkdir -p ${REMOTE_PATH}"
    
    # Sync project files to remote server using rsync
    echo_info "Syncing files to remote server (this may take a moment)..."
    rsync -avz --delete \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='.DS_Store' \
        --exclude='*.md' \
        --exclude='deploy.sh' \
        -e "ssh -o StrictHostKeyChecking=no -p ${REMOTE_PORT}" \
        ./ \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"
    
    echo_info "Project synced successfully!"
}

# Step 2: Build and push Docker image
step2_build_push() {
    echo_info "Step 2: Building and pushing Docker image..."
    
    echo_info "Building Docker image: ${DOCKER_IMAGE}"
    ssh -o StrictHostKeyChecking=no -p "${REMOTE_PORT}" \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        "cd ${REMOTE_PATH} && docker build -t ${DOCKER_IMAGE} ."
    
    echo_info "Pushing Docker image to registry..."
    ssh -o StrictHostKeyChecking=no -p "${REMOTE_PORT}" \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        "docker push ${DOCKER_IMAGE}"
    
    echo_info "Docker image built and pushed successfully!"
}

# Step 3: Restart Kubernetes deployment by deleting pods and wait for readiness
K8S_WAIT_TIMEOUT="${K8S_WAIT_TIMEOUT:-120}"

step3_restart_k8s() {
    echo_info "Step 3: Restarting Kubernetes deployment..."

    # Check if kube config file exists
    if [ ! -f "$KUBE_CONFIG" ]; then
        echo_error "Kube config file not found: ${KUBE_CONFIG}"
        exit 1
    fi

    local KCTL="kubectl --kubeconfig=$KUBE_CONFIG -n $K8S_NAMESPACE"
    local LABEL="app.kubernetes.io/name=$K8S_DEPLOYMENT"

    echo_info "Deleting pods for deployment ${K8S_DEPLOYMENT} in namespace ${K8S_NAMESPACE}..."
    $KCTL delete pods -l "$LABEL" --force --grace-period=0

    # Wait for new pod to appear
    echo_info "Waiting for new pod to be created..."
    local elapsed=0
    local interval=3
    while [ "$elapsed" -lt "$K8S_WAIT_TIMEOUT" ]; do
        local pod_name
        pod_name=$($KCTL get pods -l "$LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$pod_name" ]; then
            echo_info "New pod created: $pod_name"
            break
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done

    if [ -z "$pod_name" ]; then
        echo ""
        echo_error "Timeout: no new pod appeared within ${K8S_WAIT_TIMEOUT}s"
        exit 1
    fi

    # Wait for pod to be ready
    echo_info "Waiting for pod to become ready..."
    elapsed=0
    while [ "$elapsed" -lt "$K8S_WAIT_TIMEOUT" ]; do
        local ready
        ready=$($KCTL get pod "$pod_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$ready" = "True" ]; then
            echo_info "Pod $pod_name is ready"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done

    echo ""
    echo_error "Timeout: pod $pod_name did not become ready within ${K8S_WAIT_TIMEOUT}s"
    exit 1
}

# Main execution
main() {
    LUA_PATH="./lua/?.lua;./lua/?/init.lua;./lua/tests/?.lua;" busted lua/tests/

    echo_info "=========================================="
    echo_info "Starting deployment of iDO-Files File Server"
    echo_info "=========================================="
    echo ""
    
    # Check prerequisites
    if ! command -v kubectl &> /dev/null; then
        echo_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    
    # Execute steps
    step1_rsync
    echo ""
    
    step2_build_push
    echo ""
    
    step3_restart_k8s
    echo ""
    
    echo_info "=========================================="
    echo_info "Deployment completed successfully!"
    echo_info "=========================================="
}

# Run main function
main "$@"
