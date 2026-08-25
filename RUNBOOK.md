# Jenkins CI/CD POC — Reproduction Runbook

End-to-end instructions to reproduce the working state of
**BayajidAlam/jenkins-poc** on a fresh Poridhi VM (or any Ubuntu 24.04 host
with Docker + a GitHub PAT).

> Verified working state after build #11 (SUCCESS via webhook):
>
> - Jenkins → http://localhost:8080 (or Poridhi proxy on `:8080`)
> - Hello World site → http://localhost:8088 (or Poridhi proxy on `:8088`)
> - Webhook → delivers `push` events from `BayajidAlam/jenkins-poc`

---

## Architecture
<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/11881eb2-8d94-4978-9e8b-e28399b2363a" />



## Table of Contents

1. [Prerequisites](#prerequisites)
2. [One-shot bootstrap](#one-shot-bootstrap)
3. [Step-by-step (manual reproduction)](#step-by-step-manual-reproduction)
4. [Pipeline file (`Jenkinsfile`)](#pipeline-file-jenkinsfile)
5. [Compose file (`docker-compose.yml`)](#compose-file-docker-compose-yml)
6. [Operational checks](#operational-checks)
7. [Bugs found + fixes applied](#bugs-found-fixes-applied)
8. [Tear down](#tear-down)
9. [Re-running the pipeline](#re-running-the-pipeline)
10. [Coverage checklist (what the runbook covers)](#coverage-checklist-what-the-runbook-covers)




---

## 1. Prerequisites
You need exactly three things before you start:

| Prerequisite | How to verify | How to set |
|---|---|---|
| Docker + Compose on the VM | `docker --version && docker compose version` | Already installed on Poridhi VMs |
| A GitHub PAT with `repo` scope | Hand-create at https://github.com/settings/tokens/new | Save it locally |
| An empty `.env` in your workdir | Just create it later, line 1 = `ghp_xxxxxxxx...` | `echo "ghp_..." > .env` |

Everything else (Jenkins, plugins, jobs, credentials, webhook, pipeline
runs) is automated by the bootstrap script.

---

## 2. One-shot bootstrap
The single script `bootstrap-poc.sh` (in this repo) does all of:

1. Clones the GitHub repo
2. Sets git identity for `BayajidAlam`
3. Embeds the PAT into the git remote
4. Drops a Jenkins init script into the `jenkins_home` volume
5. `docker compose up -d` and waits for Jenkins
6. Installs all required plugins (GitHub trigger takes effect after restart)
7. Creates the `github-pat` Jenkins credential
8. Creates the `hello-world` pipeline job with the right config
9. Pings the GitHub webhook to verify delivery
10. Triggers a build via the webhook (by pushing one commit)
11. Polls Jenkins until the deploy stage succeeds
12. Verifies the live site

### To reproduce from scratch

```bash
# On a fresh Poridhi VM:
cd /home/poridhian/code            # or any workdir
git clone https://github.com/BayajidAlam/jenkins-poc.git
cd jenkins-poc
echo "ghp_YOUR_TOKEN_HERE" > .env   # <-- the only manual input
chmod 600 .env
sudo bash bootstrap-poc.sh          # see file in this repo
```

The script is idempotent — running it again skips already-completed steps.

---

## 3. Step-by-step (manual reproduction)
If you want to do it by hand (no script), follow these in order.

### 3.1 — Clone the repo and set identity

```bash
cd /home/poridhian/code
git clone https://github.com/BayajidAlam/jenkins-poc.git
cd jenkins-poc

git config --global user.name  "Bayajid Alam"
git config --global user.email "bayajidalam@users.noreply.github.com"
```

### 3.2 — Store PAT and embed it in the remote

```bash
echo "ghp_YOUR_TOKEN_HERE" > .env     # gitignored

# Make sure .env is in .gitignore
echo ".env" >> .gitignore

# Embed the PAT in the remote so we can push later
git remote set-url origin \
  "https://BayajidAlam:$(cat .env)@github.com/BayajidAlam/jenkins-poc.git"

git fetch origin main
```

### 3.3 — Persistent deploy directory on the host

The pipeline writes the built site here, and the nginx container
mounts the same path. **This must exist on the host** before the
Jenkins container starts.

```bash
sudo mkdir -p /var/jenkins-deploy/hello-world-cd
sudo chmod 777 /var/jenkins-deploy /var/jenkins-deploy/hello-world-cd
```

### 3.4 — Files this repo must contain

- `Jenkinsfile`        — the pipeline
- `docker-compose.yml` — the Jenkins container setup
- `index.html`         — the static "Hello, World!" page
- `.gitignore`         — at minimum: `.env` and `jenkins-init/`

### 3.5 — Bring Jenkins up

```bash
docker compose up -d
# wait until "Jenkins is fully up and running" appears in `docker logs jenkins`
```

### 3.6 — Skip the setup wizard

Place a Groovy file at `$JENKINS_HOME/init.groovy.d/01-setup.groovy`.
The jenkins_home volume in this repo lives at
`/var/lib/docker/volumes/<project>_jenkins_home/_data/`.

```groovy
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
instance.setCrumbIssuer(null)              // CSRF off (Poridhi proxy mangles cookies)
instance.save()
println '[init-script] admin/admin1234 created, wizard skipped, CSRF off.'
```

You can copy it into the running volume with a one-liner:

```bash
docker run --rm \
  -v <project>_jenkins_home:/data \
  -v $(pwd)/jenkins-init:/init:ro \
  alpine cp /init/01-setup.groovy /data/init.groovy.d/01-setup.groovy
```

Then `docker compose restart jenkins`.

### 3.7 — Install the plugins

Either let Jenkins suggest-and-install at first boot, or drive it via
the Groovy script console (`/scriptText` on the Jenkins API). The
following Groovy script installs everything the pipeline needs:

```groovy
import jenkins.model.*
def j = Jenkins.getInstance()
def uc = j.getUpdateCenter()

[
  'git', 'github', 'pipeline-stage-view',
  'workflow-aggregator', 'workflow-job', 'workflow-cps',
  'pipeline-groovy',
  'docker-plugin', 'docker-workflow',
  'cloudbees-folder',
  'credentials', 'credentials-binding', 'plain-credentials',
  'ssh-credentials',
  'matrix-auth',
  'github-branch-source', 'scm-api',
  'timestamper',
].each { name ->
  if (!j.getPluginManager().getPlugin(name)) {
    def p = uc.getPlugin(name)
    if (p) p.deploy()
  }
}
```

After this, restart Jenkins so the new plugins activate:

```bash
curl -X POST http://localhost:8080/safeRestart
```

### 3.8 — Create the GitHub credential

Via script console:

```groovy
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
    '<PASTE_YOUR_PAT_HERE>'
  )
)
```

> **Note:** paste the PAT directly into the `<PASTE_YOUR_PAT_HERE>`
> placeholder. This is the simplest manual path. For better security,
> mount `.env` into the container and read it with
> `new File('/var/jenkins_home/.env').text.trim()` — but that requires
> adding it to `docker-compose.yml`'s volumes section.

### 3.9 — Create the pipeline job

Via script console:

```groovy
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
  new UserRemoteConfig(
    'https://github.com/BayajidAlam/jenkins-poc.git',
    null, null, 'github-pat')
]

def job = j.createProject(WorkflowJob.class, 'hello-world')
job.setDefinition(new CpsScmFlowDefinition(scm, 'Jenkinsfile'))
job.addTrigger(new GitHubPushTrigger())
job.description = 'GitHub → Jenkins pipeline for BayajidAlam/jenkins-poc'
job.save()
```

### 3.10 — Configure the GitHub webhook

URL:
```
https://<PORIDHI_HOST>.vscode.poridhi.io/proxy/8080/github-webhook/
```

Content type: `application/json`
Events: Just the push event
Active: yes

Capture `<PORIDHI_HOST>` from the `$VSCODE_PROXY_URI` environment
variable — it looks like `6932b4db068c684dd55b0c6d_2a992cba.vscode.poridhi.io`.

You can create this from the GitHub API:

```bash
curl -X POST \
  -H "Authorization: Bearer $(cat .env)" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/BayajidAlam/jenkins-poc/hooks \
  -d '{
    "name": "web",
    "active": true,
    "events": ["push"],
    "config": {
      "url": "https://<PORIDHI_HOST>/proxy/8080/github-webhook/",
      "content_type": "json"
    }
  }'
```

### 3.11 — Verify

```bash
# ping the webhook (GitHub will POST a `ping` payload)
curl -X POST \
  -H "Authorization: Bearer $(cat .env)" \
  https://api.github.com/repos/BayajidAlam/jenkins-poc/hooks/<HOOK_ID>/pings

# should return 204. Within ~10s, Jenkins should log:
#   INFO o.j.p.g.w.s.PingGHEventSubscriber#onEvent: PING webhook received
```

Trigger a real build:

```bash
echo "<!-- $(date) -->" >> index.html
git add index.html
git commit -m "Trigger build"
git push origin main
```

Within seconds, a build appears in Jenkins. When it turns SUCCESS,
the live site updates:

```bash
curl http://localhost:8088/                # via VM
curl https://<PORIDHI_HOST>/proxy/8088/    # via Poridhi proxy
```

Both should return HTTP 200 with the updated `index.html`.

---

## 4. Pipeline file (`Jenkinsfile`)
```groovy
pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 10, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    triggers {
        githubPush()
    }

    environment {
        DEPLOY_PORT = '8088'
        SITE_NAME   = 'hello-world-cd'
    }

    stages {
        stage('Checkout') { steps { checkout scm } }

        stage('Build') {
            steps {
                echo 'Hello, World! - Building the application...'
                echo "Branch: ${env.BRANCH_NAME ?: env.GIT_BRANCH ?: 'N/A'}"
                echo "Commit: ${env.GIT_COMMIT ?: 'N/A'}"
                echo "Author: ${env.GIT_AUTHOR_NAME ?: 'N/A'}"
                sh '''
                    set -eux
                    mkdir -p build
                    date -u +'%Y-%m-%dT%H:%M:%SZ' > build/build-info.txt
                    echo "Built from commit $(git rev-parse --short HEAD)" >> build/build-info.txt
                '''
            }
        }

        stage('Test') {
            steps {
                sh '''
                    set -eux
                    test -f index.html
                    grep -q "Hello World" index.html
                '''
            }
        }

        stage('Package') {
            steps {
                sh 'tar -czf build/site.tar.gz index.html'
                archiveArtifacts artifacts: 'build/site.tar.gz', fingerprint: true
            }
        }

        stage('Deploy') {
            steps {
                sh '''#!/bin/bash           // <-- bash, not dash
                    set -eux
                    docker rm -f "${SITE_NAME}" || true

                    # Persistent deploy dir shared with nginx container
                    SITE_DIR="/var/jenkins-deploy/${SITE_NAME}"
                    mkdir -p "${SITE_DIR}"
                    cp -f index.html "${SITE_DIR}/"

                    docker run -d \
                      --name "${SITE_NAME}" \
                      --restart unless-stopped \
                      -p "${DEPLOY_PORT}:80" \
                      -v "${SITE_DIR}:/usr/share/nginx/html:ro" \
                      nginx:alpine

                    sleep 3
                    # Gateway from /proc/net/route (no `ip` cmd in jenkins image)
                    HEX_GW=$(awk 'NR>1 && $2=="00000000" {print $3}' /proc/net/route | head -1 | tr -d ' ')
                    HOST_IP=$(printf '%d.%d.%d.%d\n' \
                      "0x${HEX_GW:6:2}" "0x${HEX_GW:4:2}" \
                      "0x${HEX_GW:2:2}" "0x${HEX_GW:0:2}")
                    echo "Host gateway: ${HOST_IP}"
                    curl -fsS "http://${HOST_IP}:${DEPLOY_PORT}/" | grep -q "Hello World"
                    echo "Deployment verified."
                '''
            }
        }
    }

    post {
        success { echo 'Pipeline completed successfully 🎉' }
        failure { echo 'Pipeline failed. Check the logs above.' }
        always  { cleanWs() }
    }
}
```

---

## 5. Compose file (`docker-compose.yml`)
```yaml
services:
  jenkins:
    image: jenkins/jenkins:lts-jdk17
    container_name: jenkins
    restart: unless-stopped
    user: root
    ports:
      - "8080:8080"          # Jenkins web UI
      - "50000:50000"        # JNLP agent
      # NOTE: port 8088 is intentionally NOT mapped here.
      # The Deploy stage's nginx container publishes directly on the host.
      # If you map 8088:8088 here, the Deploy stage fails with
      #   "Bind for 0.0.0.0:8088 failed: port is already allocated".
    volumes:
      - jenkins_home:/var/jenkins_home
      - /var/run/docker.sock:/var/run/docker.sock          # docker socket
      - /usr/bin/docker:/usr/bin/docker:ro                 # docker CLI
      - /var/jenkins-deploy:/var/jenkins-deploy            # shared deploy dir
    environment:
      - JAVA_OPTS=-Djenkins.install.runSetupWizard=true -Dhudson.security.csrf.mintcrumbdisabled=true

volumes:
  jenkins_home:
```

---

## 6. Operational checks
```bash
# Jenkins reachable?
curl -fsS http://localhost:8080/api/json | head -c 200 ; echo

# Site reachable?
curl -fsS http://localhost:8088/ | head -c 200 ; echo

# Containers running?
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'

# Last build status?
curl -s http://localhost:8080/job/hello-world/lastBuild/api/json \
  | grep -oE '"result":"[^"]*"|"number":[0-9]+'

# Webhook delivery health?
curl -s -H "Authorization: Bearer $(cat .env)" \
  https://api.github.com/repos/BayajidAlam/jenkins-poc/hooks/668123213/deliveries \
  | grep -oE '"status_code":[0-9]+|"status":"[^"]+"' | head -6
```

---

## 7. Bugs found + fixes applied
These are the issues I hit while wiring the POC. Each is captured in a
git commit on `main` so you can `git log --oneline` to see them.

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `docker: not found` in Deploy stage | `jenkins/jenkins:lts-jdk17` image doesn't ship the docker CLI | Mount host `/usr/bin/docker` into the container |
| 2 | `port 8088 already allocated` when nginx starts | Pre-mapping `8088:8088` in compose + Jenkins has the docker socket = same network namespace as host, so the host port is taken | Remove `8088:8088` from `ports:` |
| 3 | `Failed to connect to localhost port 8088` from inside Jenkins | The Jenkins container has its own network namespace; `localhost` is not the host | Hit the docker bridge gateway instead of localhost |
| 4 | `Bad substitution` from the Deploy script | Jenkins' default `sh` runs through `dash`, no `${VAR:N:M}` support | Use `#!/bin/bash` shebang |
| 5 | `awwk NR>1 && $2=="00000000"` produced extra whitespace fields | The output included tabs around `eth0  00000000 010012AC ...` | Use field match `$2=="00000000"` instead of regex anchor `/^00000000/` |
| 6 | 403 on early webhook pings | Jenkins was still booting when the first `ping` arrived | Re-ping after `Jenkins is fully up` log line |
| 7 | nginx 403 Forbidden after deploy | `cleanWs()` ran after the Deploy stage and removed the workspace files that nginx was serving | Bind-mount a persistent host dir instead of mounting the workspace |
| 8 | "Stale" page served by nginx | `/var/jenkins-deploy/...` inside the Jenkins container was *not* the same path as the host's | Bind-mount `/var/jenkins-deploy` into Jenkins so `cp` and nginx's `-v` see the same dir |

Every fix is in a separate commit on `main`. To see them all:

```bash
git log --oneline
# 9119837 Clean up POC test markers from index.html
# 4856dd0 Bind-mount host deploy dir into Jenkins so cp & nginx see same path
# 8cba263 Verify end-to-end: add pipeline tag to index.html
# 2c8f353 Force bash for Deploy stage (dash doesn't support substring expansion)
# c519cf3 Fix gateway discovery: use field match instead of regex anchor
# f3ced11 Fix Deploy verify: use docker bridge gateway IP (not localhost)
# bf71aab Fix Deploy: persist site to /var/jenkins-deploy (survives cleanWs)
# 84f6cc7 Fix Deploy stage: mount docker CLI and free port 8088
```

---

## 8. Tear down
```bash
# stop Jenkins, keep jenkins_home volume
docker compose down

# stop Jenkins AND wipe jenkins_home (lose jobs, credentials, plugins)
docker compose down -v

# stop + remove the deployed nginx container
docker rm -f hello-world-cd

# remove the host deploy directory
sudo rm -rf /var/jenkins-deploy
```

To bring everything back up cleanly:

```bash
docker compose up -d
sudo mkdir -p /var/jenkins-deploy/hello-world-cd
sudo chmod 777 /var/jenkins-deploy /var/jenkins-deploy/hello-world-cd
```

Plugins and the pipeline job persist in the `jenkins_home` volume, so
they survive `docker compose down`. They are wiped only by
`docker compose down -v`.

---

## 9. Re-running the pipeline
After the POC is up, triggering a build is just a push:

```bash
cd /home/poridhian/code/jenkins-poc
echo "Edit at $(date)" >> index.html
git add index.html
git commit -m "Trigger rebuild"
git push origin main
```

Within seconds:

- GitHub delivers a `push` webhook
- Jenkins picks it up via the GitHub push trigger
- Pipeline runs Checkout → Build → Test → Package → Deploy
- nginx container is restarted with the new `index.html`
- http://localhost:8088/ shows the updated page

Watch in real time:

```bash
docker logs -f jenkins
docker logs -f hello-world-cd
```

Or via the API:

```bash
curl http://localhost:8080/job/hello-world/lastBuild/consoleText
```

---

## 10. Coverage checklist (what the runbook covers)
The runbook + `bootstrap-poc.sh` are designed so that **everything in
the current working state is reproducible**. Use this table as a
final-check before you commit any environment state to memory:

| Component | Reproduced via | Section / Step |
|---|---|---|
| Git clone of `BayajidAlam/jenkins-poc` | Section 2.1 / Section 3.1 | `git clone ...` |
| Git identity (Bayajid Alam) | Section 2.2 | `git config --global user.{name,email}` |
| Git remote with embedded PAT | Section 2.2 | `git remote set-url origin https://USER:PAT@...` |
| `.env` containing PAT (gitignored) | Section 3.2 | `echo ghp_... > .env` |
| `.gitignore` (`.env`, `jenkins-init/`) | Repo file | committed to main |
| **`Jenkinsfile`** (current version) | Repo file | committed to main |
| **`docker-compose.yml`** (current version) | Repo file | committed to main |
| **`index.html`** | Repo file | committed to main |
| **`bootstrap-poc.sh`** | Repo file (executable) | committed to main |
| **`RUNBOOK.md`** (this file) | Repo file | committed to main |
| `/var/jenkins-deploy/hello-world-cd/` host dir | Section 2.3 / Section 3.3 | `sudo mkdir -p ... && sudo chmod 777 ...` |
| Jenkins init script (skips wizard) | Section 2.4 | dropped into jenkins_home volume at `/init.groovy.d/` |
| Jenkins container (image, ports, mounts) | `docker compose up -d` (step 5) | compose file |
| Plugins installed | Section 2.6 | `scriptText` POST with install-list |
| Plugins activated | Section 2.6 | `safeRestart` |
| `github-pat` credential | Section 2.7 | `scriptText` POST |
| `hello-world` pipeline job | Section 2.8 | `scriptText` POST |
| GitHub webhook (Poridhi proxy → Jenkins) | Section 2.9 | GitHub REST API PATCH/POST |
| End-to-end build passes | Section 2.10–11 | push commit, poll Jenkins |
| Live site returns HTTP 200 | Section 2.12 | `curl http://localhost:8088/` |

When every item above can be regenerated from a fresh VM by re-running
the runbook, the POC is fully documented.
