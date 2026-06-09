# 🎯 Demo Day Cheatsheet
# KubeCon India 2026 — Keep this open during the talk!

## ⚡ Quick Commands

### Check everything is running
```bash
kubectl get nodes
kubectl get pods -n demo
kubectl get pods -n falco
kubectl get pods -n kyverno
kubectl get clusterpolicy
```

### Start Falco log stream (Terminal 1)
```bash
kubectl logs -f -n falco -l app.kubernetes.io/name=falco -c falco --since=10s
```

### Start Falco UI (Terminal 2)
```bash
kubectl port-forward svc/falco-falcosidekick-ui -n falco 2802:2802 --address 0.0.0.0
# URL: http://YOUR_EC2_IP:2802
```

### Watch CPU (Terminal 3)
```bash
watch kubectl top pods -n demo
```

### Exec into vulnerable pod (Terminal 4 - the attack)
```bash
POD=$(kubectl get pod -n demo -l app=nextjs-vulnerable -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POD -n demo -- sh
```

---

## 🎭 Attack Script (run inside pod)

```sh
# Step 1: Recon
whoami && id

# Step 2: Find SA token (Falco alert: Sensitive Token Read - CRITICAL)
cat /var/run/secrets/kubernetes.io/serviceaccount/token

# Step 3: Network recon (Falco alert: Unexpected Network Tool - WARNING)
wget -q google.com -O /dev/null

# Step 4: Cryptominer (Falco alert: Cryptominer Process Detected - CRITICAL)
dd if=/dev/zero of=/dev/null &
dd if=/dev/zero of=/dev/null &
```

---

## 🔴 Expected Falco Alerts
```
CRITICAL → Cryptominer Process Detected    tags: [cryptomining, attack]
CRITICAL → Sensitive Token Read            tags: [T1528, credential-access]
WARNING  → Unexpected Outbound Network Tool tags: [T1105, lateral-movement]
NOTICE   → Terminal shell in container     tags: [T1059, mitre_execution]
```

---

## 🛡️ Kyverno Block Tests
```bash
# All 3 should FAIL with clear error messages
kubectl apply -f manifests/kyverno/test-bad-no-limits.yaml
kubectl apply -f manifests/kyverno/test-bad-sa-token.yaml
kubectl apply -f manifests/kyverno/test-bad-privileged.yaml

# This should SUCCEED
kubectl apply -f manifests/kyverno/test-good-pod.yaml
kubectl get pod good-pod -n demo
```

---

## 🔄 Reset Demo (between runs)
```bash
# Kill miner simulation
kubectl rollout restart deployment/nextjs-vulnerable -n demo

# Wait for pod to be clean
kubectl get pods -n demo -w

# Delete test pods
kubectl delete pod bad-pod-no-limits bad-pod-sa-token bad-pod-privileged good-pod -n demo --ignore-not-found
```

---

## 🧠 Key Lines to Say on Stage

**On RCE vs Kubernetes:**
> "The RCE got the attacker INTO the container. The Service Account permissions determined how far they could GO."

**On Falco:**
> "Falco didn't stop the RCE. But the moment the attacker landed, Falco knew — pod name, namespace, image, MITRE tag. Your SOC gets this in Slack within seconds."

**On Kyverno:**
> "Kyverno doesn't patch Next.js. It enforces guardrails so that even when an app is compromised, an attacker can't deploy dangerous workloads."

**The core message:**
> "We didn't stop the RCE. We stopped the RCE from becoming a cluster-wide disaster."

---

## 🚨 If something breaks during demo

### Pod not starting?
```bash
kubectl describe pod -n demo -l app=nextjs-vulnerable
```

### Falco not showing alerts?
```bash
# Restart and re-tail
kubectl rollout restart daemonset/falco -n falco
kubectl logs -f -n falco -l app.kubernetes.io/name=falco -c falco --since=30s
```

### Kyverno not blocking?
```bash
kubectl get clusterpolicy
# All should show READY: True
kubectl describe clusterpolicy require-resource-limits
```
