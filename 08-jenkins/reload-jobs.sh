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
#   cd 08-jenkins && ./reload-jobs.sh jobs/jenkins-jobs-team-a.yaml
#
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="${SCRIPT_DIR}/jobs"
JENKINS_NS="jenkins"
SPECIFIC_FILE=""

# Parse args
for arg in "$@"; do
  case "$arg" in
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

# ── Trigger CASC reload directly (don't rely solely on sidecar timing) ───────
info "Triggering JCasC reload on Jenkins controller..."
sleep 5   # give sidecar a moment to sync files first

RELOAD_HTTP=$(kubectl exec -n "$JENKINS_NS" jenkins-0 -c jenkins -- \
  curl -sf -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:8080/reload-configuration-as-code/?casc-reload-token=jenkins-0" 2>/dev/null || echo "000")

if [ "$RELOAD_HTTP" = "200" ]; then
  info "JCasC reload triggered (HTTP 200) ✓"
else
  warn "Direct reload returned HTTP $RELOAD_HTTP — sidecar will still sync in ~30s"
fi

# ── Wait for jobs to appear in Jenkins ───────────────────────────────────────
info "Waiting for jobs to be applied (~15 seconds)..."
RETRIES=10
while [ $RETRIES -gt 0 ]; do
  JOB_COUNT=$(kubectl exec -n "$JENKINS_NS" jenkins-0 -c jenkins -- \
    find /var/jenkins_home/jobs -name config.xml 2>/dev/null | wc -l || echo "0")
  if [ "$JOB_COUNT" -gt 0 ]; then
    info "Jobs confirmed in Jenkins ($JOB_COUNT config files found) ✓"
    break
  fi
  printf "."
  sleep 3
  RETRIES=$((RETRIES - 1))
done
echo ""

if [ "$JOB_COUNT" -eq 0 ]; then
  warn "Jobs not yet visible — they may still be loading. Check Jenkins UI in ~30s."
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
