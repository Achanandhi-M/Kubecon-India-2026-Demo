# 🔐 How We Stopped a Crypto-mining Attack in Kubernetes Caused by a Next.js RCE

> **KubeCon India 2026 Demo Repo**  
> Talk by [@achanandhi](https://achanandhi.dev)  
> Demonstrating React2Shell (CVE-2025-55182) → Cryptojacking → Detection with Falco → Prevention with Kyverno

---

## 🗺️ Demo Architecture

```
EC2 (Ubuntu 26.04)
 └── k3s (single node)
      ├── namespace: demo
      │    ├── nextjs-vulnerable (React 19.0.0 - React2Shell affected)
      │    └── nextjs-sa (overpermissive ServiceAccount - intentional for demo)
      ├── namespace: falco
      │    ├── falco (runtime threat detection via eBPF)
      │    └── falco-falcosidekick-ui (alert dashboard)
      └── namespace: kyverno
           └── kyverno-admission-controller (policy enforcement)
```

---

## 🧠 Key Concepts to Remember

### The Attack Chain
```
React2Shell RCE (CVE-2025-55182)
        ↓
Attacker gains shell inside container
        ↓
Reads SA token → queries Kubernetes API
        ↓
Runs crypto-miner simulation (CPU spike)
        ↓
[Without defenses: blast radius = entire cluster]
```

### The Defense Layers
```
Layer 1 → PATCH    : Update React/Next.js (fixes the entry point)
Layer 2 → RBAC     : Least privilege SA (limits what attacker can do)
Layer 3 → Limits   : Resource limits (caps CPU the miner can steal)
Layer 4 → Falco    : Runtime detection (catches attacker behavior live)
Layer 5 → Kyverno  : Admission control (blocks dangerous configs at deploy time)
```

### Falco vs Kyverno — The key distinction
| Tool | Role | When it acts |
|---|---|---|
| Falco | **Detection** | Runtime — after pod is running |
| Kyverno | **Prevention** | Admission — before pod is created |

> ⚡ Neither tool stops the RCE itself. They stop the RCE from becoming a cluster-wide disaster.

### Service Account Mental Model
```
Service Account = Identity (WHO are you?)
RBAC            = Permissions (WHAT can you do?)
Token           = Proof of identity (mounted at /var/run/secrets/kubernetes.io/serviceaccount/token)
```

### Blast Radius
```
RCE + Weak SA permissions  = Small blast radius (container only)
RCE + Strong SA permissions = Large blast radius (entire cluster)
```

### ❓ "How did you simulate the cryptominer?" — FAQ for audiences

This is the most common question after the demo. Here's the simple explanation.

**What a real cryptominer (like XMRig) actually does:**
```
Loop forever:
  Take a math problem (hash calculation)
  Solve it using CPU
  Submit answer → earn cryptocurrency
```
The entire point is to **burn CPU continuously** to earn money.

**What our simulation does:**
```bash
dd if=/dev/zero of=/dev/null &
```
```
Loop forever:
  Read zeros from /dev/zero  (infinite source)
  Write them to /dev/null    (infinite bin)
  Repeat
```

Same effect — burns CPU continuously — but does zero crypto math. Think of it like:
```
Real miner     = treadmill running to generate electricity
Our simulation = treadmill running but plugged into nothing
```
Same CPU burn. No actual output. No real mining.

**The key insight — what Falco actually detects:**

> Falco detects **behavior, not intent**. Whether it's XMRig or `dd if=/dev/zero`, an unexpected process spawning inside a container is suspicious. Falco doesn't care what the process is doing mathematically — it cares that something unexpected is running. That's what triggered the CRITICAL alert.

**One-liner answer for your audience:**
> *"A real cryptominer burns CPU doing hash calculations. We replaced it with a Linux command that burns CPU doing nothing useful — same resource theft behavior, no actual mining. And Falco caught it either way."*

---

## 🛠️ Prerequisites

- EC2 instance: Ubuntu 22.04/24.04/26.04, t3.large or bigger
- k3s installed
- Helm v3 installed
- Docker Hub account (to push your vulnerable image)
- Port 2802 open in EC2 Security Group (for Falco UI)

---

## 🚀 Setup: Step by Step

### Step 1: EC2 Base Setup

```bash
# Configure kubectl
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
export KUBECONFIG=~/.kube/config

# Verify node is ready
kubectl get nodes
```

### Step 2: Install Metrics Server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch for k3s self-signed certs
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# Wait ~60s then verify
kubectl top nodes
```

### Step 3: Install Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### Step 4: Build & Push Vulnerable Next.js Image

> Run this on your **local Mac/Linux machine** (faster than EC2)

```bash
mkdir -p ~/demo/nextjs-vulnerable && cd ~/demo/nextjs-vulnerable
```

Create `package.json`:
```json
{
  "name": "nextjs-vulnerable",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start"
  },
  "dependencies": {
    "next": "15.1.0",
    "react": "19.0.0",
    "react-dom": "19.0.0"
  }
}
```

Create minimal app structure:
```bash
mkdir -p app

cat <<'EOF' > app/layout.js
export default function RootLayout({ children }) {
  return <html lang="en"><body>{children}</body></html>
}
EOF

cat <<'EOF' > app/page.js
export default function Home() {
  return <main><h1>Hello from Next.js (Vulnerable)</h1></main>
}
EOF

echo 'const nextConfig = {}; module.exports = nextConfig' > next.config.js
```

Create `Dockerfile`:
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install
COPY . .
EXPOSE 3000
CMD ["npm", "run", "dev"]
```

Build and push (cross-compile for EC2's x86):
```bash
docker login
docker buildx build \
  --platform linux/amd64 \
  -t YOUR_DOCKERHUB_USERNAME/nextjs-vulnerable-app:v1 \
  --push .
```

---

## 🎭 Act 1: Deploy the Vulnerable App (No Defenses)

```bash
kubectl apply -f manifests/app/
```

Verify:
```bash
kubectl get all -n demo
```

---

## ⚔️ Act 2: Simulate the Attack

### Exec into the pod (simulates RCE landing)
```bash
POD=$(kubectl get pod -n demo -l app=nextjs-vulnerable -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POD -n demo -- sh
```

### Inside the pod — attacker recon
```sh
# Who am I?
whoami && id

# Look for Kubernetes credentials
ls /var/run/secrets/kubernetes.io/serviceaccount/
cat /var/run/secrets/kubernetes.io/serviceaccount/token

# Use stolen token to query K8s API
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
curl -s --cacert $CACERT \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/demo/pods

# Simulate cryptominer (burns CPU like XMRig)
dd if=/dev/zero of=/dev/null &
dd if=/dev/zero of=/dev/null &
```

### Watch CPU spike (second terminal)
```bash
watch kubectl top pods -n demo
# You'll see CPU climb to 800m+ with no limits to stop it
```

---

## 🔍 Act 3: Detection with Falco

### Install Falco

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
kubectl apply -f manifests/falco/
```

Or via Helm directly:
```bash
helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true \
  --set falcosidekick.enabled=true \
  --set falcosidekick.webui.enabled=true \
  -f manifests/falco/custom-rules-values.yaml
```

### Watch alerts in real time
```bash
kubectl logs -f -n falco -l app.kubernetes.io/name=falco -c falco --since=10s
```

### Access Falco UI
```bash
kubectl port-forward svc/falco-falcosidekick-ui -n falco 2802:2802 --address 0.0.0.0
# Open: http://YOUR_EC2_PUBLIC_IP:2802
```

### Re-run attack — watch these 3 alerts fire:
```sh
cat /var/run/secrets/kubernetes.io/serviceaccount/token  # → CRITICAL: Sensitive Token Read (T1528)
wget -q google.com -O /dev/null                          # → WARNING:  Unexpected Network Tool (T1105)
dd if=/dev/zero of=/dev/null &                           # → CRITICAL: Cryptominer Process Detected
```

### Expected Falco Alert Summary
| Rule | Priority | MITRE Tag | Triggered By |
|---|---|---|---|
| Terminal shell in container | Notice | T1059 | `kubectl exec` |
| Sensitive Token Read | **Critical** | T1528 | `cat token` |
| Unexpected Outbound Network Tool | Warning | T1105 | `wget` |
| Cryptominer Process Detected | **Critical** | - | `dd if=/dev/zero` |

---

## 🛡️ Act 4: Prevention with Kyverno

### Install Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set admissionController.replicas=1 \
  --set backgroundController.enabled=false \
  --set cleanupController.enabled=false \
  --set reportsController.enabled=false
```

### Apply Policies

```bash
kubectl apply -f manifests/kyverno/
kubectl get clusterpolicy
```

### Test: Try to deploy bad pods (all should be BLOCKED)

```bash
# Test 1: No resource limits → BLOCKED
kubectl apply -f manifests/kyverno/test-bad-no-limits.yaml

# Test 2: automountServiceAccountToken: true → BLOCKED
kubectl apply -f manifests/kyverno/test-bad-sa-token.yaml

# Test 3: Privileged container → BLOCKED
kubectl apply -f manifests/kyverno/test-bad-privileged.yaml

# Test 4: Good pod (all policies satisfied) → ALLOWED ✅
kubectl apply -f manifests/kyverno/test-good-pod.yaml
```

### Kyverno Policy Summary
| Policy | What it blocks | Why it matters |
|---|---|---|
| `require-resource-limits` | Pods without CPU/memory limits | Stops miner from eating the node |
| `block-automount-sa-token` | Pods with SA token mounted | Stops credential theft after RCE |
| `block-privileged-containers` | Privileged pods | Prevents container escape |
| `require-non-root` | Root user containers | Limits attacker's access post-RCE |

---

## 🧹 Cleanup

```bash
kubectl delete namespace demo
kubectl delete namespace falco
kubectl delete namespace kyverno
kubectl delete clusterpolicy --all
```

---

## 📚 Talk Abstract

> Modern frameworks help teams move fast, but a single vulnerability can quickly escalate into a serious security incident. In this talk, we simulate a real-world attack scenario where a publicly disclosed RCE vulnerability in Next.js is exploited to deploy crypto-mining workloads inside a Kubernetes cluster. We demonstrate how an application-level vulnerability can quickly escalate into a cluster-wide threat - and how to prevent it before it does. We'll break down how such an attack unfolds, the runtime indicators that can expose it, and why patching the application alone isn't enough. We'll then demonstrate how to stop this class of attack using Falco for runtime threat detection and Kyverno for policy enforcement - detecting malicious activity, blocking misuse, and limiting blast radius. Finally, we'll share Kubernetes security best practices including resource limits, workload isolation, security policies, and improved runtime visibility to help teams better secure their clusters.

---

## 🔗 References

- [CVE-2025-55182 - NVD](https://nvd.nist.gov/vuln/detail/CVE-2025-55182)
- [React2Shell - Wiz Research](https://www.wiz.io/blog/critical-vulnerability-in-react-cve-2025-55182)
- [Falco Documentation](https://falco.org/docs/)
- [Kyverno Documentation](https://kyverno.io/docs/)
- [MITRE ATT&CK T1059](https://attack.mitre.org/techniques/T1059/)
- [MITRE ATT&CK T1528](https://attack.mitre.org/techniques/T1528/)
