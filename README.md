# How We Stopped a Crypto-mining Attack in Kubernetes Caused by a Next.js RCE

KubeCon India 2026 

This repo has everything you need to reproduce the demo from the talk — the vulnerable app, Falco detection rules, Kyverno policies, and a cheatsheet for running it live. The attack scenario is based on React2Shell (CVE-2025-55182), a critical RCE in React Server Components that was actively exploited in the wild to deploy cryptominers.

---

## What this demo shows

Most Kubernetes security incidents don't start in Kubernetes. They start in the application. This demo walks through exactly that:

1. A Next.js app running React 19.0.0 (affected by React2Shell) gets compromised
2. The attacker lands a shell inside the container
3. They steal the mounted Service Account token and query the Kubernetes API
4. They run a cryptominer simulation — CPU spikes with nothing to stop it
5. Falco catches every step of the attack in real time
6. Kyverno policies block the dangerous configurations before they even deploy

The point of the talk is not "look how scary RCE is." It's that patching Next.js alone isn't enough. You need runtime detection and policy enforcement so that when the next vulnerability drops, your cluster doesn't become someone else's mining rig.

---

## Demo architecture

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

## Key concepts

### The attack chain

```
React2Shell RCE (CVE-2025-55182)
        |
        v
Attacker gains shell inside container
        |
        v
Reads SA token → queries Kubernetes API
        |
        v
Runs cryptominer simulation (CPU spike)
        |
        v
Without defenses: blast radius = entire cluster
```

### The defense layers

```
Layer 1 - Patch        : Update React/Next.js (fixes the entry point)
Layer 2 - RBAC         : Least privilege SA (limits what attacker can do after RCE)
Layer 3 - Limits       : Resource limits (caps CPU the miner can steal)
Layer 4 - Falco        : Runtime detection (catches attacker behavior live)
Layer 5 - Kyverno      : Admission control (blocks dangerous configs at deploy time)
```

### Falco vs Kyverno

| Tool | Role | When it acts |
|---|---|---|
| Falco | Detection | Runtime — after the pod is running |
| Kyverno | Prevention | Admission — before the pod is created |

Neither tool stops the RCE itself. Together they stop the RCE from becoming a cluster-wide disaster.

### Service Account mental model

```
Service Account = Identity    (WHO are you?)
RBAC            = Permissions (WHAT can you do?)
Token           = Proof       (mounted at /var/run/secrets/kubernetes.io/serviceaccount/token)
```

### Blast radius

```
RCE + weak SA permissions   = small blast radius  (container only)
RCE + strong SA permissions = large blast radius  (entire cluster)
```

### How we simulated the cryptominer

This comes up in every Q&A so it's worth explaining clearly.

A real cryptominer like XMRig does this:

```
loop forever:
  take a math problem (hash calculation)
  solve it using CPU
  submit answer → earn cryptocurrency
```

The whole point is to burn CPU continuously to earn money.

Our simulation does this:

```bash
dd if=/dev/zero of=/dev/null &
```

```
loop forever:
  read zeros from /dev/zero  (infinite source)
  write them to /dev/null    (infinite bin)
  repeat
```

Same effect — burns CPU continuously — but does zero crypto math. Think of it like a treadmill running but not connected to anything. Same energy spent, nothing produced.

The important thing is that Falco detects behavior, not intent. Whether it's XMRig or `dd if=/dev/zero`, an unexpected process spawning inside a container is suspicious. Falco doesn't care what the process is doing mathematically — it cares that something unexpected is running. That's what triggered the CRITICAL alert.

Short answer for when someone asks during Q&A:
> "A real cryptominer burns CPU doing hash calculations. We replaced it with a Linux command that burns CPU doing nothing useful — same resource theft behavior, no actual mining. Falco caught it either way."

---

## Prerequisites

- EC2 running Ubuntu 22.04, 24.04, or 26.04 — t3.large minimum
- k3s installed on the EC2
- Helm v3
- Docker Hub account to push the vulnerable image
- Port 2802 open in your EC2 security group (for the Falco UI)

---

## Setup

### Step 1: Configure kubectl

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
export KUBECONFIG=~/.kube/config

kubectl get nodes
```

### Step 2: Install metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# k3s uses self-signed certs so we need this patch
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# wait ~60 seconds then verify
kubectl top nodes
```

### Step 3: Install Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### Step 4: Build and push the vulnerable Next.js image

Run this on your local machine, not the EC2 — it's much faster.

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

Create the minimal app:

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

Build for linux/amd64 (EC2 is x86, Mac M-series is ARM — buildx handles the cross-compilation):

```bash
docker login
docker buildx build \
  --platform linux/amd64 \
  -t YOUR_DOCKERHUB_USERNAME/nextjs-vulnerable-app:v1 \
  --push .
```

---

## Act 1: Deploy the vulnerable app (no defenses)

```bash
# update YOUR_DOCKERHUB_USERNAME in manifests/app/deployment.yaml first
kubectl apply -f manifests/app/
kubectl get all -n demo
```

---

## Act 2: Simulate the attack

Exec into the pod — this simulates the attacker landing after RCE:

```bash
POD=$(kubectl get pod -n demo -l app=nextjs-vulnerable -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POD -n demo -- sh
```

Inside the pod, run through the attacker recon steps:

```sh
# who am i running as?
whoami && id

# look for kubernetes credentials
ls /var/run/secrets/kubernetes.io/serviceaccount/
cat /var/run/secrets/kubernetes.io/serviceaccount/token

# use the stolen token to query the k8s API
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
curl -s --cacert $CACERT \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/demo/pods

# start the cryptominer simulation
dd if=/dev/zero of=/dev/null &
dd if=/dev/zero of=/dev/null &
```

Watch CPU spike in another terminal:

```bash
watch kubectl top pods -n demo
# climbs to 800m+ with nothing to stop it
```

---

## Act 3: Detection with Falco

Install Falco:

```bash
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
```

Tail the alerts:

```bash
kubectl logs -f -n falco -l app.kubernetes.io/name=falco -c falco --since=10s
```

Access the Falco UI:

```bash
kubectl port-forward svc/falco-falcosidekick-ui -n falco 2802:2802 --address 0.0.0.0
# open http://YOUR_EC2_PUBLIC_IP:2802
```

Re-run the attack and watch these fire:

```sh
cat /var/run/secrets/kubernetes.io/serviceaccount/token   # CRITICAL: Sensitive Token Read (T1528)
wget -q google.com -O /dev/null                           # WARNING:  Unexpected Network Tool (T1105)
dd if=/dev/zero of=/dev/null &                            # CRITICAL: Cryptominer Process Detected
```

Expected alerts:

| Rule | Priority | MITRE tag | Triggered by |
|---|---|---|---|
| Terminal shell in container | Notice | T1059 | `kubectl exec` |
| Sensitive Token Read | Critical | T1528 | `cat token` |
| Unexpected Outbound Network Tool | Warning | T1105 | `wget` |
| Cryptominer Process Detected | Critical | — | `dd if=/dev/zero` |

---

## Act 4: Prevention with Kyverno

Install Kyverno:

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

Apply the policies:

```bash
kubectl apply -f manifests/kyverno/policies.yaml
kubectl get clusterpolicy
```

Test that bad pods get blocked:

```bash
kubectl apply -f manifests/kyverno/test-bad-no-limits.yaml    # blocked: no resource limits
kubectl apply -f manifests/kyverno/test-bad-sa-token.yaml     # blocked: SA token mounted
kubectl apply -f manifests/kyverno/test-bad-privileged.yaml   # blocked: privileged container
kubectl apply -f manifests/kyverno/test-good-pod.yaml         # allowed: satisfies all policies
```

What each policy does:

| Policy | What it blocks | Why it matters |
|---|---|---|
| `require-resource-limits` | Pods without CPU/memory limits | Stops miner from eating the entire node |
| `block-automount-sa-token` | Pods with SA token mounted | Stops credential theft after RCE |
| `block-privileged-containers` | Privileged pods | Prevents container escape |
| `require-non-root` | Root user containers | Limits attacker's access post-RCE |

---

## Cleanup

```bash
kubectl delete namespace demo
kubectl delete namespace falco
kubectl delete namespace kyverno
kubectl delete clusterpolicy --all
```

---

## Talk abstract

Modern frameworks help teams move fast, but a single vulnerability can quickly escalate into a serious security incident. In this talk, we simulate a real-world attack scenario where a publicly disclosed RCE vulnerability in Next.js is exploited to deploy crypto-mining workloads inside a Kubernetes cluster. We demonstrate how an application-level vulnerability can quickly escalate into a cluster-wide threat — and how to prevent it before it does. We break down how such an attack unfolds, the runtime indicators that can expose it, and why patching the application alone isn't enough. We then demonstrate how to stop this class of attack using Falco for runtime threat detection and Kyverno for policy enforcement — detecting malicious activity, blocking misuse, and limiting blast radius. Finally, we share Kubernetes security best practices including resource limits, workload isolation, security policies, and improved runtime visibility.

---

## References

- [CVE-2025-55182 - NVD](https://nvd.nist.gov/vuln/detail/CVE-2025-55182)
- [React2Shell - Wiz Research](https://www.wiz.io/blog/critical-vulnerability-in-react-cve-2025-55182)
- [Falco Documentation](https://falco.org/docs/)
- [Kyverno Documentation](https://kyverno.io/docs/)
- [MITRE ATT&CK T1059](https://attack.mitre.org/techniques/T1059/)
- [MITRE ATT&CK T1528](https://attack.mitre.org/techniques/T1528/)
