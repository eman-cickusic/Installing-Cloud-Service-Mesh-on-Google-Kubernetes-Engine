#!/bin/bash

# Cloud Service Mesh Installation Script
# This script downloads and installs Cloud Service Mesh on the GKE cluster

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_status "Starting Cloud Service Mesh installation..."

# Load environment variables
if [[ -f "configs/environment-vars.sh" ]]; then
    source configs/environment-vars.sh
    print_status "Environment variables loaded"
else
    print_error "Environment variables file not found. Please run setup.sh first."
    exit 1
fi

# Verify kubectl is connected to the cluster
print_status "Verifying cluster connection..."
if ! kubectl cluster-info &>/dev/null; then
    print_error "kubectl is not connected to a cluster. Please run setup.sh first."
    exit 1
fi

print_success "Connected to cluster: $(kubectl config current-context)"

# Download asmcli
print_status "Downloading asmcli..."
ASM_VERSION="1.20"
ASMCLI_URL="https://storage.googleapis.com/csm-artifacts/asm/asmcli_${ASM_VERSION}"

if [[ -f "asmcli" ]]; then
    print_status "asmcli already exists, backing up..."
    mv asmcli asmcli.backup.$(date +%Y%m%d_%H%M%S)
fi

curl -L ${ASMCLI_URL} > asmcli
chmod +x asmcli

print_success "asmcli downloaded and made executable"

# Enable required APIs
print_status "Enabling Service Mesh API..."
gcloud services enable mesh.googleapis.com --quiet

print_success "Service Mesh API enabled"

# Validate ASM installation prerequisites
print_status "Validating ASM installation prerequisites..."
print_warning "This may take a few minutes..."

./asmcli validate \
  --project_id $PROJECT_ID \
  --cluster_name $CLUSTER_NAME \
  --cluster_location $CLUSTER_ZONE \
  --fleet_id $PROJECT_ID \
  --output_dir ./asm_output

print_success "ASM validation completed"

# Install Cloud Service Mesh
print_status "Installing Cloud Service Mesh..."
print_warning "This will take several minutes..."

./asmcli install \
  --project_id $PROJECT_ID \
  --cluster_name $CLUSTER_NAME \
  --cluster_location $CLUSTER_ZONE \
  --fleet_id $PROJECT_ID \
  --output_dir ./asm_output \
  --enable_all \
  --option legacy-default-ingressgateway \
  --ca mesh_ca \
  --enable_gcp_components

print_success "Cloud Service Mesh installed successfully"

# Verify ASM installation
print_status "Verifying ASM installation..."

# Check istio-system namespace
kubectl get namespace istio-system

# Check ASM pods
print_status "ASM Control Plane pods:"
kubectl get pods -n istio-system

# Check ASM services
print_status "ASM Services:"
kubectl get svc -n istio-system

# Set up ingress gateway
print_status "Setting up Istio Ingress Gateway..."

GATEWAY_NS=istio-gateway
kubectl create namespace $GATEWAY_NS --dry-run=client -o yaml | kubectl apply -f -

# Get the revision label
REVISION=$(kubectl get deploy -n istio-system -l app=istiod -o \
jsonpath={.items[*].metadata.labels.'istio\.io\/rev'}'{"\n"}')

print_status "Istio revision: ${REVISION}"

# Apply revision labels to namespaces
kubectl label namespace $GATEWAY_NS \
istio.io/rev=$REVISION --overwrite

kubectl label namespace default istio-injection=enabled --overwrite
kubectl label namespace $GATEWAY_NS istio-injection=enabled --overwrite

# Deploy ingress gateway
print_status "Deploying Istio Ingress Gateway..."
cd asm_output

kubectl apply -n $GATEWAY_NS \
  -f samples/gateways/istio-ingressgateway

print_success "Istio Ingress Gateway deployed"

# Enable sidecar injection for default namespace
print_status "Enabling sidecar injection for default namespace..."
kubectl label namespace default istio.io/rev=$REVISION --overwrite

print_success "Sidecar injection enabled"

# Wait for ingress gateway to be ready
print_status "Waiting for ingress gateway to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/istio-ingressgateway -n $GATEWAY_NS

# Get ingress gateway external IP
print_status "Getting ingress gateway external IP..."
for i in {1..10}; do
    EXTERNAL_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [[ -n "$EXTERNAL_IP" ]]; then
        break
    fi
    print_status "Waiting for external IP... (attempt $i/10)"
    sleep 30
done

if [[ -n "$EXTERNAL_IP" ]]; then
    print_success "Ingress gateway external IP: $EXTERNAL_IP"
    echo "export GATEWAY_URL=${EXTERNAL_IP}" >> ../configs/environment-vars.sh
else
    print_warning "External IP not yet assigned. Check later with:"
    echo "kubectl get svc istio-ingressgateway -n istio-system"
fi

# Save ASM information
cd ..
echo "ASM Installation completed at: $(date)" > asm-installation-info.txt
echo "Revision: $REVISION" >> asm-installation-info.txt
echo "Gateway Namespace: $GATEWAY_NS" >> asm-installation-info.txt
if [[ -n "$EXTERNAL_IP" ]]; then
    echo "Gateway External IP: $EXTERNAL_IP" >> asm-installation-info.txt
fi

print_success "Cloud Service Mesh installation completed!"
print_status "Installation information saved to asm-installation-info.txt"
print_status "Next step: Run './scripts/deploy-bookinfo.sh' to deploy the sample application"