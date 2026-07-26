#!/usr/bin/env bash
# ============================================================
# reload-jobs.sh — Update Jenkins jobs WITHOUT restarting the pod
#
# HOW IT WORKS:
#   Jenkins runs a 'config-reload' sidecar (kiwigrid/k8s-sidecar) that:
#     1. Watches ConfigMaps with label: jenkins-jenkins-config=true
#     2. On change → copies data to /var/jenkins_home/casc_configs/
#     3. POSTs to /reload-configuration-as-code/ on Jenkins controller
#     4. Jenkins applies the new JCasC → jobs created/updated in-place
#
#   Job changes NEVER require a pod restart.
#   Only plugin/security/auth changes in jenkins-values.yaml need restart.
#
# USAGE:
#   # Edit job definitions
#   vim 08-jenkins/jenkins-jobs.yaml
#
#   # Apply without restart
#   cd 08-jenkins && ./reload-jobs.sh
#   # or: ./reload-jobs.sh --wait    (waits for reload to complete)
#
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_CM="${SCRIPT_DIR}/jenkins-jobs.yaml"
JENKINS_NS="jenkins"
WAIT_MODE="${1:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
[ -f "$JOBS_CM" ] || { echo "ERROR: $JOBS_CM not found"; exit 1; }
kubectl get ns "$JENKINS_NS" &>/dev/null || { echo "ERROR: namespace $JENKINS_NS not found"; exit 1; }

# Validate YAML before applying
python3 -c "import yaml; yaml.safe_load(open('${JOBS_CM}')); print('YAML valid')" 2>/dev/null || {
  echo "ERROR: $JOBS_CM is not valid YAML"; exit 1
}

# ── Apply ConfigMap ───────────────────────────────────────────────────────────
info "Applying jenkins-jobs.yaml ConfigMap to namespace: $JENKINS_NS"
kubectl apply -f "$JOBS_CM" 2>&1
info "ConfigMap applied ✓"

# ── Wait for sidecar to trigger reload ───────────────────────────────────────
info "Waiting for config-reload sidecar to detect change (~15-30 seconds)..."

if [ "$WAIT_MODE" = "--wait" ]; then
  # Poll Jenkins logs for reload confirmation
  RETRIES=20
  while [ $RETRIES -gt 0 ]; do
    RELOAD_LOG=$(kubectl logs -n "$JENKINS_NS" -l app.kubernetes.io/component=jenkins-controller \
      -c config-reload --tail=5 2>/dev/null | grep -i "reload\|casc" | tail -1 || echo "")
    if [ -n "$RELOAD_LOG" ]; then
      info "Sidecar triggered reload: $RELOAD_LOG"
      break
    fi
    printf "."
    sleep 3
    RETRIES=$((RETRIES - 1))
  done
  echo ""
  info "Reload complete — jobs updated in Jenkins ✓"
else
  echo "  Sidecar will reload automatically in ~15-30 seconds."
  echo "  Use '--wait' flag to block until reload: ./reload-jobs.sh --wait"
fi

# ── Show what jobs currently exist ───────────────────────────────────────────
echo ""
info "Current job structure in Jenkins:"
kubectl exec -n "$JENKINS_NS" jenkins-0 -c jenkins -- \
  bash -c "find /var/jenkins_home/jobs -name config.xml 2>/dev/null \
    | sed 's|/var/jenkins_home/jobs/||;s|/config.xml||' \
    | sort | grep -v '@' | grep -v 'builds'" 2>/dev/null | head -30

echo ""
cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════╗
║  To trigger a build after updating jobs:                             ║
║                                                                       ║
║  kubectl exec -n jenkins jenkins-0 -c jenkins -- bash -c "           ║
║    CRUMB=\$(curl -sf -c /tmp/c.txt http://localhost:8080/crumbIssuer/api/json | \\
║      grep -o '\"crumb\":\"[^\"]*\"' | awk -F'\"' '{print \$4}')     ║
║    curl -sf -X POST -b /tmp/c.txt \\                                 ║
║      -H \"Jenkins-Crumb: \$CRUMB\" \\                                 ║
║      'http://localhost:8080/job/FOLDER/job/JOB/build'               ║
║  "                                                                    ║
╚═══════════════════════════════════════════════════════════════════════╝
EOF
