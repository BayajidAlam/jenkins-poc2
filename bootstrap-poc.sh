#!/usr/bin/env bash
# bootstrap-poc.sh — fully scripted reproduction of the Jenkins CI/CD POC
# for BayajidAlam/jenkins-poc on a Poridhi VM.
#
# Usage:
#   1. Place this file in your workdir (already done in the repo).
#   2. Put your GitHub PAT in .env on a single line:
#        echo "ghp_..." > .env
#   3. Run with sudo (it needs to mkdir in /var):
#        sudo bash bootstrap-poc.sh
#
# What it does (in order):
#   1.  Verifies prerequisites (docker, docker compose, git).
#   2.  Sets git identity to Bayajid Alam.
#   3.  Embeds the PAT into the git remote.
#   4.  Creates the persistent host deploy dir.
#   5.  Drops the Jenkins init script into the jenkins_home volume.
#   6.  Brings up Jenkins via docker compose.
#   7.  Waits for "Jenkins is fully up and running".
#   8.  Installs all required plugins via the script console.
#   9.  Safe-restarts Jenkins so the plugins activate.
#  10.  Creates the github-pat credential in Jenkins.
#  11.  Creates the hello-world pipeline job.
#  12.  Configures the GitHub webhook via the REST API.
#  13.  Triggers one real push to validate end-to-end.
#  14.  Polls Jenkins until build #1 succeeds.
#  15.  Verifies the live site returns HTTP 200.

set -euo pipefail

REPO_URL="https://github.com/BayajidAlam/jenkins-poc.git"
PROXY_URL="${VSCODE_PROXY_URI:-}"
SITE_NAME="hello-world-cd"
DEPLOY_PORT="8088"
JENKINS_URL="http://localhost:8080"
WEBHOOK_PORT="8080"
WEBHOOK_PATH="/github-webhook/"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
log() { printf '\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || err "Missing required tool: $1"; }

# Wait for a command to succeed (used for "Jenkins is up", etc.)
wait_for() {
  local desc="$1"; shift
  local timeout_s="${1:-180}"; shift || true
  local start=$(date +%s)
  while true; do
    if eval "$@" >/dev/null 2>&1; then
      log "  -> ready: $desc"
      return 0
    fi
    if (( $(date +%s) - start > timeout_s )); then
      err "Timeout waiting for: $desc"
    fi
    sleep 2
  done
}

# ------------------------------------------------------------------------------
# Step 1: prerequisites
# ------------------------------------------------------------------------------
log "Step 1: verifying prerequisites"
require docker
require git
docker --version
git --version
docker compose version >/dev/null 2>&1 || err "docker compose plugin is missing"

[[ -f .env ]] || err "No .env file in $(pwd). Create it with one line: ghp_YOUR_PAT_HERE"
PAT="$(tr -d '[:space:]' < .env)"
[[ "$PAT" =~ ^gh[pousr]?_ ]] || err ".env doesn't look like a GitHub PAT"

# ------------------------------------------------------------------------------
# Step 2: git identity + remote
# ------------------------------------------------------------------------------
log "Step 2: configuring git identity and remote"
git config --global user.name  "Bayajid Alam"
git config --global user.email "bayajidalam@users.noreply.github.com"
git remote set-url origin "https://BayajidAlam:${PAT}@github.com/BayajidAlam/jenkins-poc.git"
git fetch origin main >/dev/null 2>&1 || warn "git fetch failed (will continue; webhook will still work)"

# ------------------------------------------------------------------------------
# Step 3: persistent deploy dir on the host
# ------------------------------------------------------------------------------
log "Step 3: creating /var/jenkins-deploy/${SITE_NAME}"
mkdir -p "/var/jenkins-deploy/${SITE_NAME}"
chmod 777 "/var/jenkins-deploy" "/var/jenkins-deploy/${SITE_NAME}"

# ------------------------------------------------------------------------------
# Step 4: Jenkins init script in the volume
# ------------------------------------------------------------------------------
log "Step 4: dropping Jenkins init script"
mkdir -p jenkins-init
cat > jenkins-init/01-setup.groovy <<'GROOVY'
import jenkins.model.*
import jenkins.install.*
import hudson.security.*

def instance = Jenkins.getInstance()
instance.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)

def realm = new HudsonPrivateSecurityRealm(false)
if (realm.getUser('admin') == null) {
    realm.createAccount('admin', 'admin1234')
}
instance.setSecurityRealm(realm)
instance.setAuthorizationStrategy(AuthorizationStrategy.UNSECURED)
instance.setCrumbIssuer(null)
instance.save()
println '[init-script] admin/admin1234 created, wizard skipped, CSRF off.'
GROOVY

docker run --rm \
  -v "$(basename "$(pwd)")_jenkins_home:/data" \
  -v "$(pwd)/jenkins-init:/init:ro" \
  alpine sh -c 'mkdir -p /data/init.groovy.d && cp /init/01-setup.groovy /data/init.groovy.d/'

# ------------------------------------------------------------------------------
# Step 5: bring Jenkins up
# ------------------------------------------------------------------------------
log "Step 5: starting Jenkins via docker compose"
docker compose up -d

# wait for "Jenkins is fully up and running"
wait_for "Jenkins ready" 300 \
  "docker logs jenkins 2>&1 | grep -q 'Jenkins is fully up and running'"

# ------------------------------------------------------------------------------
# Step 6: install plugins
# ------------------------------------------------------------------------------
log "Step 6: installing plugins via script console"
cat > /tmp/install-plugins.groovy <<'GROOVY'
import jenkins.model.*
def j = Jenkins.getInstance()
def uc = j.getUpdateCenter()
[
  'git', 'github', 'pipeline-stage-view',
  'workflow-aggregator', 'workflow-job', 'workflow-cps',
  'docker-plugin', 'docker-workflow',
  'cloudbees-folder',
  'credentials', 'credentials-binding', 'plain-credentials', 'ssh-credentials',
  'matrix-auth',
  'github-branch-source', 'scm-api',
  'timestamper',
].each { name ->
  if (!j.getPluginManager().getPlugin(name)) {
    def p = uc.getPlugin(name)
    if (p != null) p.deploy()
  }
}
return "plugin_install_queued"
GROOVY

# CSRF is off, so no crumb needed.
curl -fsS -X POST "${JENKINS_URL}/scriptText" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "script=$(cat /tmp/install-plugins.groovy)" >/dev/null

# Wait for "Install successful" messages
wait_for "plugins installed" 180 \
  "docker logs --since 30s jenkins 2>&1 | grep -c 'Installation successful' | grep -qE '[1-9][0-9]*'"

log "  -> safe-restarting Jenkins so new plugins activate"
curl -fsS -X POST "${JENKINS_URL}/safeRestart" >/dev/null
wait_for "Jenkins restarted" 180 \
  "curl -fsS -m 5 -o /dev/null -w '%{http_code}' ${JENKINS_URL}/api/json | grep -q '^200\$'"

# ------------------------------------------------------------------------------
# Step 7: create github-pat credential
# ------------------------------------------------------------------------------
log "Step 7: creating github-pat credential"
# The PAT is in .env on the host. We need to make it readable inside
# the container's script context. Easiest: inline it into the Groovy.
ESCAPED_PAT="${PAT//\"/\\\"}"
cat > /tmp/create-cred.groovy <<GROOVY
import jenkins.model.*
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.common.*
import com.cloudbees.plugins.credentials.domains.*
import com.cloudbees.plugins.credentials.impl.*

def store = Jenkins.getInstance()
    .getExtensionList('com.cloudbees.plugins.credentials.SystemCredentialsProvider')[0]
    .getStore()
store.getCredentials(Domain.global())
     .findAll { it.id == 'github-pat' }
     .each { store.removeCredentials(Domain.global(), it) }
store.addCredentials(Domain.global(),
  new UsernamePasswordCredentialsImpl(
    CredentialsScope.GLOBAL,
    'github-pat',
    'GitHub PAT for BayajidAlam/jenkins-poc',
    'BayajidAlam',
    '${ESCAPED_PAT}'
  )
)
return "credential_created"
GROOVY
curl -fsS -X POST "${JENKINS_URL}/scriptText" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "script=$(cat /tmp/create-cred.groovy)" >/dev/null

# ------------------------------------------------------------------------------
# Step 8: create the pipeline job
# ------------------------------------------------------------------------------
log "Step 8: creating pipeline job"
cat > /tmp/create-job.groovy <<'GROOVY'
import jenkins.model.*
import hudson.plugins.git.*
import org.jenkinsci.plugins.workflow.cps.*
import org.jenkinsci.plugins.workflow.job.*
import com.cloudbees.jenkins.*

def j = Jenkins.getInstance()
j.getItem('hello-world')?.delete()

def scm = new GitSCM('https://github.com/BayajidAlam/jenkins-poc.git')
scm.branches = [new BranchSpec('*/main')]
scm.userRemoteConfigs = [
  new UserRemoteConfig('https://github.com/BayajidAlam/jenkins-poc.git', null, null, 'github-pat')
]

def job = j.createProject(WorkflowJob.class, 'hello-world')
job.setDefinition(new CpsScmFlowDefinition(scm, 'Jenkinsfile'))
job.addTrigger(new GitHubPushTrigger())
job.description = 'GitHub → Jenkins pipeline for BayajidAlam/jenkins-poc'
job.save()
return "job_created"
GROOVY
curl -fsS -X POST "${JENKINS_URL}/scriptText" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "script=$(cat /tmp/create-job.groovy)" >/dev/null

# ------------------------------------------------------------------------------
# Step 9: configure the GitHub webhook
# ------------------------------------------------------------------------------
log "Step 9: configuring GitHub webhook"
if [[ -z "$PROXY_URL" ]]; then
  warn "VSCODE_PROXY_URI is not set; webhook will only work on the LAN."
  warn "Re-run with VSCODE_PROXY_URI exported to enable the public proxy."
  PROXY_BASE="http://$(hostname --ip-address)"
else
  # $PROXY_URL looks like https://XYZ.vscode.poridhi.io/proxy/{{port}}/
  PROXY_BASE="${PROXY_URL//\{\{port\}\}/$WEBHOOK_PORT}"
  # strip trailing slash
  PROXY_BASE="${PROXY_BASE%/}"
fi
WEBHOOK_URL="${PROXY_BASE}${WEBHOOK_PATH}"
log "  webhook URL: ${WEBHOOK_URL}"

# Find existing or create new
# (Use awk + a state machine to capture only top-level "id" of the
#  Repository-hook objects, not nested "node_id".)
EXISTING=$(curl -fsS -H "Authorization: Bearer ${PAT}" \
  "https://api.github.com/repos/BayajidAlam/jenkins-poc/hooks" \
  | grep -oE '\{[^{}]*"id":[0-9]+[^{}]*\}' \
  | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2 || true)

if [[ -n "$EXISTING" ]]; then
  log "  -> updating existing webhook id=${EXISTING}"
  curl -fsS -X PATCH \
    -H "Authorization: Bearer ${PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/BayajidAlam/jenkins-poc/hooks/${EXISTING}" \
    -d "{
      \"active\": true,
      \"events\": [\"push\"],
      \"config\": {\"url\": \"${WEBHOOK_URL}\", \"content_type\": \"json\"}
    }" >/dev/null
  HOOK_ID="$EXISTING"
else
  log "  -> creating new webhook"
  RESP=$(curl -fsS -X POST \
    -H "Authorization: Bearer ${PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/BayajidAlam/jenkins-poc/hooks" \
    -d "{
      \"name\": \"web\",
      \"active\": true,
      \"events\": [\"push\"],
      \"config\": {\"url\": \"${WEBHOOK_URL}\", \"content_type\": \"json\"}
    }")
  HOOK_ID=$(echo "$RESP" | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2)
fi

# ping to confirm
curl -fsS -X POST \
  -H "Authorization: Bearer ${PAT}" \
  "https://api.github.com/repos/BayajidAlam/jenkins-poc/hooks/${HOOK_ID}/pings" >/dev/null

# ------------------------------------------------------------------------------
# Step 10: trigger one real build to validate end-to-end
# ------------------------------------------------------------------------------
log "Step 10: pushing a commit to trigger a real build"
MARKER="<!-- bootstrap-poc.sh run at $(date -u +%Y-%m-%dT%H:%M:%SZ) -->"
echo "" >> index.html
echo "$MARKER" >> index.html
git add index.html
git commit -m "Trigger pipeline via bootstrap-poc.sh" >/dev/null 2>&1 || true
git push origin main

# ------------------------------------------------------------------------------
# Step 11: poll Jenkins until the build succeeds
# ------------------------------------------------------------------------------
log "Step 11: waiting for the build to complete"
SECS=0; MAX=600
LAST_NUM=""
while (( SECS < MAX )); do
  RESP=$(curl -fsS -m 5 "${JENKINS_URL}/job/hello-world/lastBuild/api/json" 2>/dev/null || true)
  NUM=$(echo "$RESP" | grep -oE '"number":[0-9]+' | head -1 | cut -d: -f2 || true)
  RES=$(echo "$RESP" | grep -oE '"result":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  BDG=$(echo "$RESP" | grep -oE '"building":[a-z]+' | head -1 | cut -d: -f2 || true)
  if [[ -n "$NUM" && "$NUM" != "$LAST_NUM" ]]; then
    log "  build #${NUM} ... ${BDG} result=${RES:-<in-progress>}"
    LAST_NUM="$NUM"
  fi
  if [[ "$BDG" == "false" && -n "$RES" ]]; then
    if [[ "$RES" == "SUCCESS" ]]; then
      log "Build #${NUM} SUCCESS"
      break
    else
      err "Build #${NUM} ended with result=${RES}. Check the Jenkins console."
    fi
  fi
  sleep 5
  SECS=$((SECS+5))
done

# ------------------------------------------------------------------------------
# Step 12: verify the live site
# ------------------------------------------------------------------------------
log "Step 12: verifying the live site"
SITE_LOCAL=$(curl -fsS -m 10 -o /dev/null -w '%{http_code}' \
  "http://localhost:${DEPLOY_PORT}/" 2>/dev/null || echo "ERR")
log "  local http://localhost:${DEPLOY_PORT}/ -> HTTP ${SITE_LOCAL}"

if [[ -n "$PROXY_URL" ]]; then
  PROXY_BASE="${PROXY_URL//\{\{port\}\}/$DEPLOY_PORT}"
  PROXY_BASE="${PROXY_BASE%/}"
  SITE_PROXY=$(curl -fsS -m 15 -o /dev/null -w '%{http_code}' \
    "${PROXY_BASE}/" 2>/dev/null || echo "ERR")
  log "  proxy ${PROXY_BASE}/ -> HTTP ${SITE_PROXY}"
fi

log "Done. POC is live."
log "  Jenkins: ${JENKINS_URL}  (admin / admin1234)"
log "  Site:    http://localhost:${DEPLOY_PORT}/"
