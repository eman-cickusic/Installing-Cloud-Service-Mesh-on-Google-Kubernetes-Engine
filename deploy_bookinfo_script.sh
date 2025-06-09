#!/bin/bash

# Bookinfo Application Deployment Script
# This script deploys the Istio Bookinfo sample application

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

print_status "Starting Bookinfo application deployment..."

# Load environment variables
if [[ -f "configs/environment-vars.sh" ]]; then
    source configs/environment-vars.sh
    print_status "Environment variables loaded"
else
    print_error "Environment variables file not found. Please run setup.sh first."
    exit 1
fi

# Verify ASM is installed
if [[ ! -d "asm_output" ]]; then
    print_error "ASM output directory not found. Please run install-asm.sh first."
    exit 1
fi

# Change to ASM output directory
cd asm_output

# Find Istio directory
ISTIO_DIR=$(ls -d istio-* | tail -n 1)
if [[ -z "$ISTIO_DIR" ]]; then
    print_error "Istio directory not found in asm_output"
    exit 1
fi

print_status "Using Istio directory: $ISTIO_DIR"
cd $ISTIO_DIR

# Verify cluster connection
print_status "Verifying cluster connection..."
if ! kubectl cluster-info &>/dev/null; then
    print_error "kubectl is not connected to a cluster"
    exit 1
fi

print_success "Connected to cluster: $(kubectl config current-context)"

# Deploy Bookinfo application
print_status "Deploying Bookinfo application..."

# Show the application configuration
print_status "Bookinfo application components:"
echo "  - productpage: Frontend service"
echo "  - details: Book information service"
echo "  - reviews: Book reviews service (3 versions)"
echo "  - ratings: Book rating service"

# Deploy the application
kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml

print_success "Bookinfo application deployed"

# Wait for pods to be ready
print_status "Waiting for application pods to be ready..."
kubectl wait --for=condition=ready pod -l app=productpage --timeout=300s
kubectl wait --for=condition=ready pod -l app=details --timeout=300s
kubectl wait --for=condition=ready pod -l app=ratings --timeout=300s
kubectl wait --for=condition=ready pod -l app=reviews --timeout=300s

print_success "All application pods are ready"

# Show pod status
print_status "Application pod status:"
kubectl get pods -l 'app in (productpage,details,ratings,reviews)'

# Configure ingress gateway
print_status "Configuring Bookinfo ingress gateway..."
kubectl apply -f samples/bookinfo/networking/bookinfo-gateway.yaml

print_success "Bookinfo gateway configured"

# Verify gateway
print_status "Verifying gateway configuration..."
kubectl get gateway
kubectl get virtualservice

# Test internal connectivity
print_status "Testing internal application connectivity..."
RATINGS_POD=$(kubectl get pod -l app=ratings -o jsonpath='{.items[0].metadata.name}')
if [[ -n "$RATINGS_POD" ]]; then
    TITLE_CHECK=$(kubectl exec -it $RATINGS_POD -c ratings -- curl -s productpage:9080/productpage | grep -o "<title>.*</title>" || echo "")
    if [[ "$TITLE_CHECK" == "<title>Simple Bookstore App</title>" ]]; then
        print_success "Internal connectivity test passed"
    else
        print_warning "Internal connectivity test failed or incomplete"
    fi
else
    print_warning "Could not find ratings pod for connectivity test"
fi

# Get external access information
print_status "Getting external access information..."

# Get ingress gateway service
GATEWAY_SERVICE=$(kubectl get svc istio-ingressgateway -n istio-system -o json)
EXTERNAL_IP=$(echo $GATEWAY_SERVICE | grep -o '"ip":"[^"]*"' | cut -d'"' -f4)
EXTERNAL_HOSTNAME=$(echo $GATEWAY_SERVICE | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4)

if [[ -n "$EXTERNAL_IP" ]]; then
    GATEWAY_URL=$EXTERNAL_IP
    print_success "External IP: $EXTERNAL_IP"
elif [[ -n "$EXTERNAL_HOSTNAME" ]]; then
    GATEWAY_URL=$EXTERNAL_HOSTNAME
    print_success "External Hostname: $EXTERNAL_HOSTNAME"
else
    print_warning "External IP/Hostname not yet assigned"
    kubectl get svc istio-ingressgateway -n istio-system
    print_status "Check the EXTERNAL-IP column above"
    GATEWAY_URL="<PENDING>"
fi

# Test external connectivity
if [[ "$GATEWAY_URL" != "<PENDING>" ]]; then
    print_status "Testing external connectivity..."
    for i in {1..5}; do
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://${GATEWAY_URL}/productpage || echo "000")
        if [[ "$HTTP_STATUS" == "200" ]]; then
            print_success "External connectivity test passed"
            break
        else
            print_status "Waiting for external connectivity... (attempt $i/5)"
            sleep 10
        fi
    done
    
    if [[ "$HTTP_STATUS" != "200" ]]; then
        print_warning "External connectivity test failed (HTTP $HTTP_STATUS)"
        print_status "The application may still be starting up"
    fi
fi

# Create access information file
cd ../..
cat > bookinfo-access-info.txt << EOF
Bookinfo Application Access Information
======================================

Generated: $(date)

Application URL: http://${GATEWAY_URL}/productpage

Services:
- productpage: Main application frontend
- details: Book details service  
- reviews: Book reviews service (3 versions)
- ratings: Book ratings service

To access the application:
1. Open your web browser
2. Navigate to: http://${GATEWAY_URL}/productpage
3. Refresh the page multiple times to see different review versions

Load Testing:
sudo apt install siege
siege http://${GATEWAY_URL}/productpage

Monitoring:
- Access Cloud Service Mesh dashboard in GCP Console
- Go to Anthos > Service Mesh
- Select your cluster to view metrics

Cleanup:
kubectl delete -f samples/bookinfo/platform/kube/bookinfo.yaml
kubectl delete -f samples/bookinfo/networking/bookinfo-gateway.yaml
EOF

print_success "Bookinfo application deployment completed!"
print_status "Access information saved to bookinfo-access-info.txt"

if [[ "$GATEWAY_URL" != "<PENDING>" ]]; then
    echo ""
    echo "🌐 Application URL: http://${GATEWAY_URL}/productpage"
    echo ""
    print_status "You can now:"
    echo "  1. Open the URL in your browser"
    echo "  2. Refresh the page to see different versions of reviews"
    echo "  3. Monitor the application in Cloud Service Mesh dashboard"
    echo "  4. Generate load with: siege http://${GATEWAY_URL}/productpage"
else
    echo ""
    print_warning "External IP is still pending. Check with:"
    echo "kubectl get svc istio-ingressgateway -n istio-system"
    echo "Once available, access the app at: http://<EXTERNAL-IP>/productpage"
fi