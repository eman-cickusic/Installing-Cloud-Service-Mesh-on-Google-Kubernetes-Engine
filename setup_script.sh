#!/bin/bash

# Cloud Service Mesh on GKE - Initial Setup Script
# This script sets up the project environment and creates the GKE cluster

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

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_status "Starting Cloud Service Mesh setup..."

# Check prerequisites
print_status "Checking prerequisites..."

if ! command_exists gcloud; then
    print_error "gcloud CLI is not installed. Please install it first."
    exit 1
fi

if ! command_exists kubectl; then
    print_error "kubectl is not installed. Please install it first."
    exit 1
fi

print_success "Prerequisites check completed"

# Configure environment variables
print_status "Configuring environment variables..."

export PROJECT_ID=$(gcloud config get-value project)
if [[ -z "$PROJECT_ID" ]]; then
    print_error "No project is set. Please run: gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi

export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} \
    --format="value(projectNumber)")
export CLUSTER_NAME=${CLUSTER_NAME:-central}
export CLUSTER_ZONE=${CLUSTER_ZONE:-us-central1-a}
export WORKLOAD_POOL=${PROJECT_ID}.svc.id.goog
export MESH_ID="proj-${PROJECT_NUMBER}"

# Save environment variables to file
cat > configs/environment-vars.sh << EOF
#!/bin/bash
export PROJECT_ID=${PROJECT_ID}
export PROJECT_NUMBER=${PROJECT_NUMBER}
export CLUSTER_NAME=${CLUSTER_NAME}
export CLUSTER_ZONE=${CLUSTER_ZONE}
export WORKLOAD_POOL=${WORKLOAD_POOL}
export MESH_ID=${MESH_ID}
EOF

print_success "Environment variables configured"
print_status "Project ID: ${PROJECT_ID}"
print_status "Cluster Name: ${CLUSTER_NAME}"
print_status "Cluster Zone: ${CLUSTER_ZONE}"

# Verify permissions
print_status "Verifying IAM permissions..."

CURRENT_USER=$(gcloud config get-value core/account 2>/dev/null)
IAM_CHECK=$(gcloud projects get-iam-policy $PROJECT_ID \
    --flatten="bindings[].members" \
    --filter="bindings.members:user:${CURRENT_USER}" \
    --format="value(bindings.role)" | grep -E "(roles/owner|roles/editor)" | head -1)

if [[ -z "$IAM_CHECK" ]]; then
    print_warning "Could not verify sufficient permissions. You need one of the following roles:"
    echo "  - Project Owner"
    echo "  - Project Editor"
    echo "  - Or the combination of: Kubernetes Engine Admin, Project IAM Admin, GKE Hub Admin, Service Account Admin"
else
    print_success "IAM permissions verified (${IAM_CHECK})"
fi

# Enable required APIs
print_status "Enabling required Google Cloud APIs..."

REQUIRED_APIS=(
    "container.googleapis.com"
    "compute.googleapis.com"
    "monitoring.googleapis.com"
    "logging.googleapis.com"
    "cloudtrace.googleapis.com"
    "meshca.googleapis.com"
    "meshtelemetry.googleapis.com"
    "meshconfig.googleapis.com"
    "iamcredentials.googleapis.com"
    "gkeconnect.googleapis.com"
    "gkehub.googleapis.com"
    "cloudresourcemanager.googleapis.com"
)

for api in "${REQUIRED_APIS[@]}"; do
    print_status "Enabling ${api}..."
    gcloud services enable ${api} --quiet
done

print_success "All required APIs enabled"

# Set compute zone
print_status "Setting compute zone to ${CLUSTER_ZONE}..."
gcloud config set compute/zone ${CLUSTER_ZONE}

# Create GKE cluster
print_status "Creating GKE cluster '${CLUSTER_NAME}'..."
print_warning "This will take several minutes..."

gcloud container clusters create ${CLUSTER_NAME} \
    --machine-type=e2-standard-4 \
    --num-nodes=4 \
    --subnetwork=default \
    --release-channel=regular \
    --labels mesh_id=${MESH_ID} \
    --workload-pool=${WORKLOAD_POOL} \
    --logging=SYSTEM,WORKLOAD \
    --monitoring=SYSTEM \
    --enable-ip-alias \
    --enable-autoscaling \
    --min-nodes=2 \
    --max-nodes=6 \
    --enable-autorepair \
    --enable-autoupgrade

print_success "GKE cluster created successfully"

# Get cluster credentials
print_status "Getting cluster credentials..."
gcloud container clusters get-credentials ${CLUSTER_NAME} \
     --zone $CLUSTER_ZONE \
     --project $PROJECT_ID

# Create cluster admin binding
print_status "Creating cluster admin binding..."
kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole=cluster-admin \
    --user=${CURRENT_USER} \
    --dry-run=client -o yaml | kubectl apply -f -

print_success "Cluster admin binding created"

# Verify cluster is ready
print_status "Verifying cluster status..."
kubectl cluster-info

print_success "Setup completed successfully!"
print_status "Next steps:"
echo "  1. Run './scripts/install-asm.sh' to install Cloud Service Mesh"
echo "  2. Run './scripts/deploy-bookinfo.sh' to deploy the sample application"

# Save cluster info
kubectl cluster-info > cluster-info.txt
print_status "Cluster information saved to cluster-info.txt"