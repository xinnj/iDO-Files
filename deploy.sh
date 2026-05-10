#!/bin/bash

# Deploy script for iDO-Files File Server
# This script:
# 1. SCP project to remote server
# 2. Build and push Docker image
# 3. Restart Kubernetes deployment

set -e  # Exit on error

# Load configuration from env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env"

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
    ssh -o StrictHostKeyChecking=no \
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
        -e "ssh -o StrictHostKeyChecking=no" \
        ./ \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"
    
    echo_info "Project synced successfully!"
}

# Step 2: Build and push Docker image
step2_build_push() {
    echo_info "Step 2: Building and pushing Docker image..."
    
    echo_info "Building Docker image: ${DOCKER_IMAGE}"
    ssh -o StrictHostKeyChecking=no \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        "cd ${REMOTE_PATH} && docker build -t ${DOCKER_IMAGE} ."
    
    echo_info "Pushing Docker image to registry..."
    ssh -o StrictHostKeyChecking=no \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        "docker push ${DOCKER_IMAGE}"
    
    echo_info "Docker image built and pushed successfully!"
}

# Step 3: Restart Kubernetes deployment by deleting pods
step3_restart_k8s() {
    echo_info "Step 3: Deleting pods to trigger restart..."
    
    # Check if kube config file exists
    if [ ! -f "$KUBE_CONFIG" ]; then
        echo_error "Kube config file not found: ${KUBE_CONFIG}"
        exit 1
    fi
    
    echo_info "Deleting pods for deployment ${K8S_DEPLOYMENT} in namespace ${K8S_NAMESPACE}..."
    kubectl --kubeconfig="$KUBE_CONFIG" \
        -n "$K8S_NAMESPACE" \
        delete pods -l app.kubernetes.io/name="$K8S_DEPLOYMENT" --force --grace-period=0
    
    echo_info "Pods deleted successfully! New pods will be created automatically."
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
