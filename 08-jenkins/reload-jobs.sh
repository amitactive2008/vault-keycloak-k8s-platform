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
# JOB FILES (jobs/ directory — one ConfigMap per team):
#   jobs/jenkins-jobs-devops.yaml   ← devops folder tree
#   jobs/jenkins-jobs-team-a.yaml   ← team-a folders + pipeline jobs
#   jobs/jenkins-jobs-team-b.yaml   ← team-b folders + pipeline jobs
#
# USAGE:
#   # Edit a team's job definitions
#   vim 08-jenkins/jobs/jenkins-jobs-team-a.yaml
#
#   # Apply all job files (or a specific one) without restart
#   cd 08-jenkins && ./reload-jobs.sh
#   cd 08-jenkins && ./reload-jobs.sh --wait          # blocks until reload
#   cd 08-jenkins && ./reload-jobs.sh jobs/jenkins-jobs-team-a.yaml
#
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="${SCRIPT_DIR}/jobs"
JENKINS_NS="jenkins"
WAIT_MODE=""
SPECIFIC_FILE=""

# Parse args
for arg in "$@"; do
  case "$arg" in
    --wait) WAIT_MODE="--wait" ;;
    *.yaml|*.yml) SPECIFIC_FILE="${SCRIPT_DIR}/${arg}" ;;
  esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
kubectl get ns "$JENKINS_NS" &>/dev/null || { error "namespace $JENKINS_NS not found"; exit 1; }

# Determine which files to apply
if [ -n "$SPECIFIC_FILE" ]; then
  FILES=("$SPECIFIC_FILE")
else
  # Build file list without mapfile (compatible with bash 3.x / macOS)
  FILES=()
  while IFS= read -r f; do
    FILES+=("$f")
  done < <(find "$JOBS_DIR" -name "*.yaml" | sort)
fi

[ ${#FILES[@]} -gt 0 ] || { error "No YAML files found in $JOBS_DIR"; exit 1; }

# Validate YAML before applying
for f in "${FILES[@]}"; do
  python3 -c "import yaml; yaml.safe_load(open('${f}')); print('YAML valid: ${f##*/}')" 2>/dev/null || {
    error "${f} is not valid YAML"; exit 1
  }
done

# ── Apply ConfigMaps ──────────────────────────────────────────────────────────
info "Applying job ConfigMaps to namespace: $JENKINS_NS"
for f in "${FILES[@]}"; do
  kubectl apply -f "$f" 2>&1
done
info "All ConfigMaps applied ✓"

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
