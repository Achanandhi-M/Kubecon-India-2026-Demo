#!/bin/bash
# setup.sh - One-shot EC2 setup script for KubeCon demo
# Run this on a fresh EC2 Ubuntu instance with k3s already installed
# Usage: bash setup.sh YOUR_DOCKERHUB_USERNAME

set -e

DOCKERHUB_USER=${1:-"YOUR_DOCKERHUB_USERNAME"}

echo "🚀 KubeCon Demo Setup Starting..."
echo "Using DockerHub image: ${DOCKERHUB_USER}/nextjs-vulnerable-app:v1"

# Step 1: Configure kubectl
echo "📦 Configuring kubectl..."
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
export KUBECONFIG=~/.kube/config
grep -q 'KUBECONFIG' ~/.bashrc || echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc

# Step 2: Install Helm
echo "⚙️  Installing Helm..."
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Step 3: Install Metrics Server
echo "📊 Installing Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# Step 4: Deploy vulnerable app
echo "🎯 Deploying vulnerable Next.js app..."
sed "s/YOUR_DOCKERHUB_USERNAME/${DOCKERHUB_USER}/g" manifests/app/deployment.yaml | kubectl apply -f -

# Step 5: Install Falco
echo "🔍 Installing Falco..."
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true \
  --set falcosidekick.enabled=true \
  --set falcosidekick.webui.enabled=true \
  -f manifests/falco/custom-rules-values.yaml

# Step 6: Install Kyverno
echo "🛡️  Installing Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set admissionController.replicas=1 \
  --set backgroundController.enabled=false \
  --set cleanupController.enabled=false \
  --set reportsController.enabled=false

# Step 7: Apply Kyverno policies
echo "📋 Applying Kyverno policies..."
kubectl apply -f manifests/kyverno/policies.yaml

echo ""
echo "✅ Setup complete! Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=nextjs-vulnerable -n demo --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=falco -n falco --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kyverno -n kyverno --timeout=120s

echo ""
echo "🎉 All done! Your demo environment is ready."
echo ""
echo "Next steps:"
echo "  1. Open DEMO-CHEATSHEET.md and follow along"
echo "  2. Run: kubectl get pods -n demo -n falco -n kyverno"
echo "  3. Port-forward Falco UI: kubectl port-forward svc/falco-falcosidekick-ui -n falco 2802:2802 --address 0.0.0.0"
