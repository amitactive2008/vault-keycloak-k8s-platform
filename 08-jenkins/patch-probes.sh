#!/usr/bin/env bash
# ============================================================
# patch-probes.sh — Fix Jenkins health probes after helm upgrade
#
# WHY THIS EXISTS:
#   The Jenkins Helm chart v5.9.40 hardcodes 'httpGet /login' as the probe
#   type in its templates regardless of tcpSocket values set in values.yaml.
#   With anonymous access disabled (no Overall/Read for anonymous), the
#   httpGet /login probe returns 403 → pod enters CrashLoopBackOff.
#
#   This script patches the StatefulSet directly to use tcpSocket probes,
#   which simply check if the port is accepting connections (no HTTP auth).
#
# WHEN TO RUN:
#   After every: helm upgrade jenkins jenkins/jenkins ...
#   i.e. after any change to jenkins-values.yaml that requires Helm upgrade.
#
# USAGE:
#   chmod +x 08-jenkins/patch-probes.sh
#   ./08-jenkins/patch-probes.sh
# ============================================================
set -euo pipefail

JENKINS_NS="jenkins"

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }

info "Patching Jenkins StatefulSet probes: httpGet → tcpSocket ..."

kubectl patch statefulset jenkins -n "$JENKINS_NS" --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/startupProbe",
    "value": {
      "tcpSocket": {"port": 8080},
      "failureThreshold": 12,
      "initialDelaySeconds": 90,
      "periodSeconds": 10,
      "timeoutSeconds": 5
    }
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/livenessProbe",
    "value": {
      "tcpSocket": {"port": 8080},
      "failureThreshold": 5,
      "initialDelaySeconds": 120,
      "periodSeconds": 10,
      "timeoutSeconds": 5
    }
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/readinessProbe",
    "value": {
      "tcpSocket": {"port": 8080},
      "failureThreshold": 3,
      "initialDelaySeconds": 30,
      "periodSeconds": 10,
      "timeoutSeconds": 5
    }
  }
]'

info "StatefulSet patched ✓"

# Restart the pod to pick up the new probe spec
info "Restarting jenkins-0 to apply new probes ..."
kubectl delete pod jenkins-0 -n "$JENKINS_NS" 2>/dev/null || true
kubectl wait pod -n "$JENKINS_NS" \
  -l app.kubernetes.io/component=jenkins-controller \
  --for=condition=Ready --timeout=600s

info "Jenkins is Ready with tcpSocket probes ✓"

# Verify
PROBE_TYPE=$(kubectl get pod jenkins-0 -n "$JENKINS_NS" \
  -o jsonpath='{.spec.containers[?(@.name=="jenkins")].livenessProbe}' 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('tcpSocket ✓' if 'tcpSocket' in d else 'httpGet (NOT fixed!)')" 2>/dev/null)
info "Liveness probe: $PROBE_TYPE"
