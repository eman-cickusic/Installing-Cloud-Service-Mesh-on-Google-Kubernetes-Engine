# Installing Cloud Service Mesh on Google Kubernetes Engine

This repository contains a complete guide and automation scripts for installing Cloud Service Mesh (ASM) on Google Kubernetes Engine (GKE), including deployment of the Bookinfo sample application.

## Video

https://youtu.be/x_0kVUP6XVA

## Overview

**Istio** is an open-source framework for connecting, securing, and managing microservices. **Cloud Service Mesh (ASM)** is Google's fully managed service mesh powered by Istio, providing an Anthos-tested, fully supported distribution of Istio.

### Key Benefits of Cloud Service Mesh

- **Load balancing** and **service-to-service authentication**
- **Monitoring** and **observability** without code changes
- **Automatic retry logic** with exponential backoff
- **Service metrics and logs** automatically ingested to Google Cloud
- **Preconfigured dashboards** and **in-depth telemetry**
- **Service Level Objectives (SLOs)** and alerting capabilities

## Prerequisites

- Google Cloud Platform account with billing enabled
- `gcloud` CLI installed and configured
- `kubectl` installed
- Required IAM permissions:
  - Project Editor
  - Kubernetes Engine Admin
  - Project IAM Admin
  - GKE Hub Admin
  - Service Account Admin
  - Service Account Key Admin

## Architecture

The project deploys the Bookinfo sample application, which consists of four microservices:

- **productpage**: Frontend service that calls details and reviews
- **details**: Contains book information
- **reviews**: Contains book reviews (3 versions with different UI)
- **ratings**: Contains book ranking information

## Quick Start

### 1. Clone this repository

```bash
git clone <your-repo-url>
cd cloud-service-mesh-gke
```

### 2. Run the setup script

```bash
chmod +x scripts/setup.sh
./scripts/setup.sh
```

### 3. Install Cloud Service Mesh

```bash
chmod +x scripts/install-asm.sh
./scripts/install-asm.sh
```

### 4. Deploy the Bookinfo application

```bash
chmod +x scripts/deploy-bookinfo.sh
./scripts/deploy-bookinfo.sh
```

## Manual Installation Steps

If you prefer to run the commands manually, follow these detailed steps:

### Step 1: Project Setup

```bash
# Set up environment variables
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} \
    --format="value(projectNumber)")
export CLUSTER_NAME=central
export CLUSTER_ZONE=us-central1-a  # Change as needed
export WORKLOAD_POOL=${PROJECT_ID}.svc.id.goog
export MESH_ID="proj-${PROJECT_NUMBER}"

# Verify permissions
gcloud projects get-iam-policy $PROJECT_ID \
    --flatten="bindings[].members" \
    --filter="bindings.members:user:$(gcloud config get-value core/account 2>/dev/null)"
```

### Step 2: Create GKE Cluster

```bash
# Set compute zone
gcloud config set compute/zone ${CLUSTER_ZONE}

# Create the cluster
gcloud container clusters create ${CLUSTER_NAME} \
    --machine-type=e2-standard-4 \
    --num-nodes=4 \
    --subnetwork=default \
    --release-channel=regular \
    --labels mesh_id=${MESH_ID} \
    --workload-pool=${WORKLOAD_POOL} \
    --logging=SYSTEM,WORKLOAD

# Get cluster credentials
gcloud container clusters get-credentials ${CLUSTER_NAME} \
     --zone $CLUSTER_ZONE \
     --project $PROJECT_ID

# Create cluster admin binding
kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole=cluster-admin \
    --user=$(whoami)@$(gcloud config get-value core/account | cut -d'@' -f2)
```

### Step 3: Install Cloud Service Mesh

```bash
# Download asmcli
curl https://storage.googleapis.com/csm-artifacts/asm/asmcli_1.20 > asmcli
chmod +x asmcli

# Enable required APIs
gcloud services enable mesh.googleapis.com

# Validate configuration
./asmcli validate \
  --project_id $PROJECT_ID \
  --cluster_name $CLUSTER_NAME \
  --cluster_location $CLUSTER_ZONE \
  --fleet_id $PROJECT_ID \
  --output_dir ./asm_output

# Install ASM
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
```

### Step 4: Configure Ingress Gateway

```bash
# Create gateway namespace
GATEWAY_NS=istio-gateway
kubectl create namespace $GATEWAY_NS

# Get revision label
REVISION=$(kubectl get deploy -n istio-system -l app=istiod -o \
jsonpath={.items[*].metadata.labels.'istio\.io\/rev'}'{"\n"}')

# Apply revision label to namespaces
kubectl label namespace $GATEWAY_NS \
istio.io/rev=$REVISION --overwrite

kubectl label namespace default istio-injection=enabled
kubectl label namespace $GATEWAY_NS istio-injection=enabled

# Deploy ingress gateway
cd ~/asm_output
kubectl apply -n $GATEWAY_NS \
  -f samples/gateways/istio-ingressgateway

# Enable sidecar injection for default namespace
kubectl label namespace default istio-injection-istio.io/rev=$REVISION --overwrite
```

### Step 5: Deploy Bookinfo Application

```bash
# Find Istio directory
istio_dir=$(ls -d istio-* | tail -n 1)
cd $istio_dir

# Deploy Bookinfo
kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml

# Configure ingress gateway
kubectl apply -f samples/bookinfo/networking/bookinfo-gateway.yaml

# Get external IP
kubectl get svc istio-ingressgateway -n istio-system

# Test the application
export GATEWAY_URL=[EXTERNAL-IP]  # Replace with actual IP
curl -I http://${GATEWAY_URL}/productpage
```

## Testing the Application

### Access the Web Interface

1. Get the external IP of the ingress gateway:
```bash
kubectl get svc istio-ingressgateway -n istio-system
```

2. Open your browser and navigate to:
```
http://[EXTERNAL-IP]/productpage
```

3. Refresh the page several times to see different versions of the reviews service:
   - No stars (v1)
   - Black stars (v2)
   - Red stars (v3)

### Generate Load Testing

Install and use siege for load testing:

```bash
# Install siege
sudo apt install siege

# Generate traffic
siege http://${GATEWAY_URL}/productpage
```

## Monitoring and Observability

Access the Cloud Service Mesh dashboard in the Google Cloud Console:

1. Go to **Anthos** > **Service Mesh** in the Cloud Console
2. Select your cluster to view:
   - Service topology
   - Traffic metrics
   - Error rates
   - Latency percentiles
   - Service Level Objectives (SLOs)

## Cleanup

To avoid ongoing charges, clean up the resources:

```bash
# Delete the cluster
gcloud container clusters delete ${CLUSTER_NAME} --zone=${CLUSTER_ZONE}

# Delete any remaining resources
kubectl delete -f samples/bookinfo/platform/kube/bookinfo.yaml
kubectl delete -f samples/bookinfo/networking/bookinfo-gateway.yaml
```

## Troubleshooting

### Common Issues

1. **Validation errors**: These are usually informational and can be ignored during the validation step
2. **Pod not ready**: Wait for all pods to be in "Running" status before proceeding
3. **External IP pending**: Wait for the LoadBalancer service to provision an external IP

### Useful Commands

```bash
# Check pod status
kubectl get pods

# Check services
kubectl get services

# Check gateways
kubectl get gateway

# View logs
kubectl logs -f deployment/productpage-v1

# Check ASM installation
kubectl get pods -n istio-system
```

## File Structure

```
cloud-service-mesh-gke/
├── README.md
├── scripts/
│   ├── setup.sh
│   ├── install-asm.sh
│   ├── deploy-bookinfo.sh
│   └── cleanup.sh
├── configs/
│   ├── cluster-config.yaml
│   └── environment-vars.sh
└── docs/
    ├── architecture.md
    └── troubleshooting.md
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## References

- [Cloud Service Mesh Documentation](https://cloud.google.com/service-mesh/docs)
- [Istio Documentation](https://istio.io/latest/docs/)
- [Google Kubernetes Engine Documentation](https://cloud.google.com/kubernetes-engine/docs)
- [Bookinfo Sample Application](https://istio.io/latest/docs/examples/bookinfo/)
