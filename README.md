# Jenkins POC - CI/CD with Always-On Docker Compose Agents → Docker Hub

A Jenkins pipeline that builds a static nginx site and pushes the resulting Docker
image to Docker Hub. The Jenkins controller **and both agents** run as persistent
services in `docker-compose.yml` - there is no per-stage container spin-up. Every
parameterized build produces a uniquely-tagged image.

> **The `Jenkinsfile` is the single source of truth for this pipeline's contract.**
> All parameters, defaults, credential IDs, plugin requirements, naming convention,
> and first-build gotchas are documented in the comment block at the top of
> [`Jenkinsfile`](./Jenkinsfile). This README is only the operator quickstart.

---

## 1. What you get

- **Everything runs from one `docker compose up -d`** - Jenkins controller plus
  the two agents. No ephemeral agents.
- `jenkins-controller` - the Jenkins UI and JNLP listener.
- `jenkins-agent-build` - persistent agent, label **`build`**, runs Checkout +
  Build. Has the docker CLI and `/var/run/docker.sock` mounted (DooD).
- `jenkins-agent-push` - persistent agent, label **`push`**, runs Push to Docker
  Hub. Has the docker CLI and `/var/run/docker.sock` mounted.
- Agents connect to the controller over JNLP at first boot using the
  `JENKINS_URL` / `JENKINS_SECRET` / `JENKINS_AGENT_NAME` env vars declared in
  `docker-compose.yml`. After that they stay online - `restart: unless-stopped`
  on every service.
- The pipeline stages route by label: `agent { label 'build' }` and
  `agent { label 'push' }`. No container is launched per stage.

### Why two agents?

The pipeline uses **two distinct agents** rather than one because:

1. **Credential isolation** - the push-agent handles `dockerhub-creds`. Keeping
   it in a separate container limits the exposure window of those secrets.
2. **Clean Docker login state** - `docker login` is scoped to the Push stage
   only. The agent itself stays online, but no stale auth state lingers between
   builds (Jenkins does not persist env vars set via `withCredentials`).
3. **Independent failure isolation** - a broken build doesn't leave any
   half-configured push state behind, and vice versa.
4. **Always-on cost is fixed** - you pay for two idle agents, but you save the
   per-stage container spin-up cost. For CI workloads this is usually the
   better trade.

Image tag format (final Docker Hub push): `<branch>-<environment>-<YYYYMMDD>-<short-sha>`
Example: `main-dev-20260825-843b924`

## 2. Repo layout

```
jenkins-poc/
├── Jenkinsfile          # SINGLE SOURCE OF TRUTH - read the top comment block
├── Dockerfile           # nginx:alpine + sed-substituted placeholders
├── Dockerfile.agent     # Custom Jenkins agent image (jenkins/agent + docker CLI)
├── docker-compose.yml   # Jenkins controller + agent-build + agent-push
├── index.html           # The static site (with IMAGE_TAG_PLACEHOLDER / DOCKERHUB_USER placeholders)
└── README.md            # This file (operator quickstart)
```

## 3. Prerequisites - build the custom agent image FIRST

The upstream `jenkins/inbound-agent:latest-jdk17` does **not** ship with the docker
CLI, but both our agents run `docker build` and `docker push` (Docker-out-of-Docker
via `/var/run/docker.sock`). Build the custom agent image **before** bringing the
stack up - the agents will register but fail every job otherwise.

```bash
docker build -f Dockerfile.agent -t jenkins-agent-with-docker:latest-jdk17 .
docker images | grep jenkins-agent-with-docker
```

The custom image is ~520 MB and is reused by both `agent-build` and `agent-push`.

## 4. Secrets you'll need (read this first)

Three secrets come from Jenkins itself - you do not invent them. Below is the
cheat-sheet; the full step-by-step is in §7 and §8.

| # | Secret | Where to get it (exact path) |
|---|---|---|
| 1 | **Administrator password** (unlock Jenkins at first boot) | Run on the host: `docker exec jenkins-controller cat /var/jenkins_home/secrets/initialAdminPassword`. Jenkins also shows it once on the unlock screen if you hit the right URL with cookies disabled. |
| 2 | **`JENKINS_AGENT_BUILD_SECRET`** (JNLP secret for the `agent-build` node) | After creating the node in §8, open `http://<host>:8080/computer/agent-build/slave-agent.jnlp`. The **first `<argument>` inside `<application-desc>` is the secret**. Same value is shown under *Manage Jenkins → Nodes → agent-build → "Agent password" / "JNLP"* on the node's page. |
| 3 | **`JENKINS_AGENT_PUSH_SECRET`** (JNLP secret for the `agent-push` node) | Same as #2 but at `…/computer/agent-push/slave-agent.jnlp`, or *Manage Jenkins → Nodes → agent-push* (see §8). |

All three are **per-installation** - they change if you wipe the `jenkins_home`
volume (`docker compose down -v`) and have to redo the setup wizard and node
creation. The two JNLP secrets are also re-issued if you delete a node and
recreate it.

## 5. Set up `.env` (JNLP secrets only)

The two agents self-register using JNLP secrets that **Jenkins issues** - not
secrets you invent. The flow is:

1. `docker compose up -d` brings the controller up.
2. You unlock Jenkins, finish the setup wizard, and create the agent nodes via
   the UI (see §8). Each node gets a JNLP secret at creation time.
3. You put those two secrets into `.env` as `JENKINS_AGENT_BUILD_SECRET` and
   `JENKINS_AGENT_PUSH_SECRET`, then `docker compose up -d` again so the agent
   containers can dial back with the right secret.

Create a minimal `.env` in the repo root (the agent secrets are filled in later
from §8):

```bash
cat > .env <<'EOF'
# JNLP secrets - paste these from the Jenkins UI (see §4 / §8).
# Each is unique per node. Do not reuse.
JENKINS_AGENT_BUILD_SECRET=
JENKINS_AGENT_PUSH_SECRET=
EOF
```

> Git credentials (`github-pat`) and Docker Hub credentials (`dockerhub-creds`)
> are stored in Jenkins via the UI (see §9). They do NOT go in `.env`.

## 6. Bring the stack up

```bash
docker compose up -d
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

You should see one container - the controller. The agents stay stopped until
you've created their nodes in §8 and put the secrets in `.env`.

```
NAMES                  STATUS          PORTS
jenkins-controller     Up X minutes    0.0.0.0:8080->8080, 0.0.0.0:50000->50000
```

Confirm the host Docker socket is reachable from inside the controller (the
agents will need this too once they start):

```bash
docker exec jenkins-controller docker version --format '{{.Server.Version}}'
# Expected: prints the host Docker server version, e.g. 29.6.1
```

If you get "permission denied":

```bash
sudo chmod 666 /var/run/docker.sock
docker compose restart jenkins
```

## 7. First-boot Jenkins setup (UI)

Get the **initial admin password** (this is "Secret #1" from §4):

```bash
docker exec jenkins-controller cat /var/jenkins_home/secrets/initialAdminPassword
```

That prints a 32-character hex string. Copy it.

Open `http://<host>:8080`, paste the password, then in the setup wizard:

1. **Install suggested plugins** - this brings in `git`, `pipeline`,
   `credentials-binding`, `plain-credentials`, `ssh-credentials`, `ssh-slaves`,
   `workflow-aggregator`, and the SSH Build Agents / JNLP plumbing the agent
   images use to connect. Let it finish.
2. **Install the Git Parameter plugin** - after the wizard finishes, go to
   *Manage Jenkins → Plugins → Available plugins*, search **Git Parameter**,
   install it, and **restart Jenkins** when prompted. (The pipeline uses it for
   the `BRANCH` dropdown.)
3. **Create your admin user** - username and password of your choice.

> The new architecture uses **persistent JNLP agents**, so the **Docker
> Pipeline** plugin is NOT required. The pipeline does not launch containers
> per stage - it routes to pre-built agents by label.

## 8. Register the two persistent agents

This is the moment you'll grab **Secrets #2 and #3** from §4 (the JNLP
secrets). The flow has two phases because JNLP secrets are **generated by
Jenkins**, not chosen by you.

### 8.1 Phase A - first boot (controller only)

The agents will fail to start because `.env` has empty secrets (compose's
`${VAR:?...}` guard exits the agent container). That's expected. Only the
controller is up.

```
NAMES                STATUS          PORTS
jenkins-controller   Up X minutes    0.0.0.0:8080->8080, 0.0.0.0:50000->50000
```

### 8.2 Phase B - create the FIRST node (`agent-build`)

The two nodes are created identically - only the name and labels differ. Walk
through this once for `agent-build`, then repeat it once for `agent-push`.

**Step 1 - Open the Nodes page.** In the Jenkins left sidebar, click
**Manage Jenkins**, then **Nodes** (under "System"). The Nodes page lists
existing nodes (initially just the built-in `Built-In Node` controller).
Click the **New Node** link (top-right, or in the table).

**Step 2 - Name and type.** The "Create new node" page has two sections.
Fill them in as follows:

| Field | Value |
|---|---|
| **Node name** | `agent-build` (literally this - it must match `JENKINS_AGENT_NAME` in `docker-compose.yml`) |
| **Type** | Tick **Permanent Agent** (the radio button, NOT "Copy Existing Node") |

Click **Create**. You land on the configure page.

> Jenkins shows two radio choices: "Permanent Agent" and "Copy Existing
> Node". Pick Permanent Agent. There is no "OK" button here - the green
> **Create** button at the bottom submits.

**Step 3 - Configure the agent (the long form).** You now see the node
configure page, with sections collapsing down the screen. Set these fields
exactly:

| Section | Field | Value (for `agent-build`) |
|---|---|---|
| **General** | Name | `agent-build` (pre-filled) |
| | Description | (leave blank) |
| | **# of executors** | `2` |
| | **Remote root directory** | `/home/jenkins/agent` |
| | **Labels** | `build docker` (space-separated; must match what `Jenkinsfile` says: `label 'build'`) |
| | **Usage** | *Use this node as much as possible* |
| | **Launch method** | *Launch agents via JNLP* (from the dropdown; this unlocks the JNLP fields below) |
| | *Availability* | *Keep this agent online as much as possible* (the second radio) |
| **JNLP** | **Tunnel** | *(leave blank)* |
| | **JVM options** | *(leave blank)* |
| | **Internal data** | *(leave blank; "Remember the old socket..." is fine ticked by default)* |

Click **Save**.

> Common mistakes: typing `Build` instead of `build` for the label (case
> matters - the `Jenkinsfile` says `label 'build'`); typing
> `/home/jenkins/agent/` with a trailing slash (works but is ugly); picking
> "Launch agents on Unix machines via SSH" by accident (we want **JNLP**,
> not SSH).

**Step 4 - Grab the JNLP secret.** Save puts you on the node's landing
page. **This is where the JNLP secret lives** - it was just generated.

Scroll down past the "Status" / "Connect" / "Owner" sections to a section
that is labeled one of:
- **"Agent password"** (older Jenkins), or
- **"Agent → JNLP → Secret"** (newer Jenkins).

It will either show a copyable hex string labeled *Secret*, or a launch
command like:

```
Secret: 9f3c8a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f
OR
java -jar agent.jar -jnlpUrl .../agent-build/agent.jnlp -secret 9f3c8a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f <node-name>
```

Copy that hex string. That is **`JENKINS_AGENT_BUILD_SECRET`**.

> The secret is 64 hex characters. If you see a much shorter or longer
> value, double-check you copied the right field (don't grab the
> `<node-name>` token, for example).

### 8.3 Phase B - create the SECOND node (`agent-push`)

Go back to **Manage Jenkins → Nodes → New Node** and repeat the §8.2 steps
verbatim, with two differences:

| Field | Value (for `agent-push`) |
|---|---|
| **Node name** | `agent-push` |
| **Labels** | `push docker` |

When you Save, grab the hex string from the "Agent password" / "JNLP /
Secret" section on the new node's landing page. That is
**`JENKINS_AGENT_PUSH_SECRET`**.

### 8.4 Alternative ways to retrieve the JNLP secrets

If you saved the nodes but missed the secret, you don't need to redo them.
Two retrieval paths:

**Path A - directly from the controller's volume** (no UI needed):

```bash
# JENKINS_AGENT_BUILD_SECRET
docker exec jenkins-controller cat \
  /var/jenkins_home/nodes/agent-build/secret.xml

# JENKINS_AGENT_PUSH_SECRET
docker exec jenkins-controller cat \
  /var/jenkins_home/nodes/agent-push/secret.xml
```

Each prints one line like `<secret>9f3c…e2</secret>`. The hex string
between the `<secret>` tags is the value to paste into `.env`.

**Path B - via the JNLP descriptor URL** (browser):

```
http://<host>:8080/computer/agent-build/slave-agent.jnlp
http://<host>:8080/computer/agent-push/slave-agent.jnlp
```

If Jenkins asks you to log in first, do that, then reload. The XML body
has `<argument>some-hex-string</argument>` as the **first `<argument>`
inside `<application-desc>`** - that hex string is the JNLP secret.

> **Truncated secret warning:** if the hex string in the JNLP URL ends
> with `…` or is shorter than 64 chars, the browser has line-wrapped it.
> Use Path A above - the on-disk `secret.xml` is the canonical source.

### 8.5 Put the secrets in `.env`, restart the stack

Edit `.env` at the repo root and paste each hex string:

```bash
JENKINS_AGENT_BUILD_SECRET=9f3c8a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f
JENKINS_AGENT_PUSH_SECRET=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
```

Then bring up the agents:

```bash
docker compose up -d
```

Within ~30 seconds, both agent containers should connect and show as
**online** on *Manage Jenkins → Nodes*. If a node stays offline, your
pasted secret doesn't match the controller - go back to §8.2 step 4 (or
§8.4 Path A) and re-copy.

> **Why pre-declare the nodes?** The agent containers use the JNLP
> self-registration built into the upstream `jenkins/inbound-agent` image,
> which only works if the controller already has a node with that name.
> Pre-declaring both nodes (each with its own secret) lets the services
> auto-connect.
>
> **Tip:** the JNLP secret is also stored in `jenkins_home` and is stable
> until you reset it from the node's configure page. If you delete a node
> and create a new one with the same name, you'll get a new secret and
> must update `.env`.
>
> **Why two agents?** The push-agent handles `dockerhub-creds`. Keeping
> it in a separate container limits the exposure window of those
> secrets, and keeps `docker login` scoped to the Push stage only. See §1
> "Why two agents?" for details.

## 9. Add credentials (github-pat, dockerhub-creds)

Go to **Manage Jenkins → Credentials → (global) → Add Credentials**.

| Credential ID | Kind | Username | Password | Required when |
|---|---|---|---|---|
| `github-pat` | Username with password | your GitHub user | your GitHub PAT (`repo` scope) | repo is private |
| `dockerhub-creds` | Username with password | your Docker Hub user | your Docker Hub PAT | always |

> **Use the UI for both credentials.** Values pasted in through scripts (curl,
> script console) sometimes get ANSI escape sequences baked in, which surface
> later as `Error response from daemon: unknown: malformed HTTP Authorization
> header` at the Push stage.

## 10. Create the pipeline job

Dashboard → **New Item** → name: `app-build-push` → type: **Pipeline** → OK.

- **Do NOT** check *This project is parameterized*. The `Jenkinsfile` declares all
  four parameters itself; doing both creates duplicate-parameter errors and the
  job will fail to load.
- Under **Pipeline**:
  - Definition: **Pipeline script from SCM**
  - SCM: **Git**
  - Repository URL: `https://github.com/BayajidAlam/jenkins-poc2.git` (or your fork)
  - Credentials: select `github-pat` (if your repo is private)
  - Branch: `*/main`
  - Script Path: `Jenkinsfile`
- Click **Save**.

The defaults baked into the `Jenkinsfile` are
`DOCKER_IMAGE=bayajidph/jenkins-poc` and
`GIT_REPO=https://github.com/BayajidAlam/jenkins-poc2.git`. Override them either
by editing the file, or by passing them at build time as parameters - they are
runtime overrides.

## 11. First-build gotchas

Two issues always hit on the first run. They are not bugs - they're Jenkins
safety mechanisms.

### 11.1 Script Approval

The very first build fails with:

```
org.jenkinsci.plugins.scriptsecurity.scripts.UnapprovedUsageException: script not yet approved for use
```

Jenkins' In-process Script Approval blocks Groovy scripts it hasn't seen before.

**Fix:** Go to **Manage Jenkins → In-process Script Approval**. Click **Approve**
for each pending script hash, then click **Build with Parameters** again. (There
is no CLI helper - the UI is the only path.)

### 11.2 First build is slow

The first build pulls `nginx:alpine` during the Build stage (the agent image is
already local from §3). Subsequent builds reuse the cache and finish in seconds.

## 12. Run the pipeline

On the job page, click **Build with Parameters**. You see four fields:

| Parameter | Type | Default / placeholder |
|---|---|---|
| `BRANCH` | Git Parameter (dropdown auto-fetched from GitHub) | placeholder `NONE` - you must actively select a branch each build |
| `ENVIRONMENT` | Choice (`dev` / `staging` / `prod`) | `dev` |
| `DOCKER_IMAGE` | String (Docker Hub repo without tag) | `bayajidph/jenkins-poc` |
| `GIT_REPO` | String (GitHub repo URL) | `https://github.com/BayajidAlam/jenkins-poc2.git` |

Click **Build**.

For each stage, Jenkins routes to the matching persistent agent - **no
container is started or stopped**:

```
[Pipeline] node (agent-build)
Running on agent-build in /home/jenkins/agent/workspace/app-build-push
... Checkout stage ...
... Build stage ...
[Pipeline] node (agent-push)
Running on agent-push in /home/jenkins/agent/workspace/app-build-push
... Push stage ...
[Pipeline] End of Pipeline
Finished: SUCCESS
```

Both agents remain online after the build finishes and are reused for the next
build.

### Verify the image on Docker Hub

From any host with Docker installed, substitute your actual values (example
shown for the `main`/`dev` default build of this repo):

```bash
docker pull bayajidph/jenkins-poc:main-dev-20260825-843b924
docker run --rm -d -p 8088:80 --name verify bayajidph/jenkins-poc:main-dev-20260825-843b924
curl -s http://localhost:8088 | grep image-tag
# <span class="tag" id="image-tag">main-dev-20260825-843b924</span>
docker stop verify && docker rm verify
```

The `<span id="image-tag">` value matches the tag, proving the Dockerfile's
`sed` substitution ran end-to-end.

## 13. Stages

See [`Jenkinsfile`](./Jenkinsfile) for the live definition.

| Stage | Where it runs | What it does |
|---|---|---|
| **Build & Package → Checkout** | `agent-build` (label `build`) | `git clone`s `${params.GIT_REPO}` at `${params.BRANCH}`. After checkout, computes the unique image tag (`${BRANCH}-${ENV}-${YYYYMMDD}-${short-sha}`). |
| **Build & Package → Build** | `agent-build` (label `build`) | Runs `docker build -t ${FULL_IMAGE} .` on the Dockerfile, substituting the IMAGE_TAG and DOCKERHUB_USER placeholders. |
| **Push to Docker Hub** | `agent-push` (label `push`) | Logs in to Docker Hub with `dockerhub-creds`, then `docker push ${FULL_IMAGE}`. |

The Checkout and Build stages share `agent-build`. The Push stage uses
`agent-push`. No agent is spun up or torn down for any stage.

## 14. Troubleshooting

**First build fails with `script not yet approved for use`** - see §11.1. Approve
scripts at *Manage Jenkins → In-process Script Approval*.

**Agents show as offline on the Nodes page** - the corresponding
`JENKINS_AGENT_BUILD_SECRET` / `JENKINS_AGENT_PUSH_SECRET` in `.env` doesn't
match what the controller has for that node.

To find the right secret, open the node in the Jenkins UI and either:
- Scroll to the **JNLP / Agent password** section on the node page, or
- Fetch `http://<host>:8080/computer/agent-build/slave-agent.jnlp` (or
  `…/agent-push/slave-agent.jnlp`) — the first `<argument>` inside
  `<application-desc>` is the secret.

Update `.env` with that value, then `docker compose up -d`. Or check the agent's
container logs:

```bash
docker logs jenkins-agent-build --tail 100
docker logs jenkins-agent-push  --tail 100
```

Look for `JNLP agent disconnected` or `Connection refused: jenkins-controller/8080`.
The latter usually means the controller container isn't fully up yet - give it
another 30 seconds and check again.

**Push stage fails with `Error response from daemon: Get "https://registry-1.docker.io/v2/": unauthorized`** -
wrong Docker Hub username or password in the `dockerhub-creds` credential. Open
*Manage Jenkins → Credentials → dockerhub-creds → Update* and re-enter them.

**Push stage fails with `unknown: malformed HTTP Authorization header`** - the
credential was set through a method that injected stray characters. Delete the
credential in the UI and re-add it manually. See §9 warning.

**Checkout stage fails with `Could not find any suitable branch`** - `BRANCH`
was passed a value that doesn't exist in the GitHub repo, or the Git Parameter
plugin failed to fetch branches. Check that `GIT_REPO` is reachable from the
`agent-build` container.

**`BRANCH` dropdown is empty** - the Git Parameter plugin couldn't fetch from
your repo. If the repo is private, the `github-pat` credential is missing or
has wrong scopes (needs `repo`). Confirm the Git Parameter plugin is installed
(see §7 step 2).

**Agent fails to talk to host Docker** - confirm `/var/run/docker.sock` is
mounted into the agent container
(`docker exec jenkins-agent-build ls -la /var/run/docker.sock`). On the host:
`chmod 666 /var/run/docker.sock`.

## 15. Day-to-day operations

| Action | Command |
|---|---|
| Start the stack | `docker compose up -d` |
| Stop the stack | `docker compose down` |
| Tail Jenkins logs | `docker logs -f jenkins-controller` |
| Tail agent logs | `docker logs -f jenkins-agent-build` / `jenkins-agent-push` |
| Restart one agent | `docker compose restart agent-build` |
| Update the agent image | `docker build -f Dockerfile.agent -t jenkins-agent-with-docker:latest-jdk17 . && docker compose up -d` |
| Wipe Jenkins state | `docker compose down -v` (DESTROYS all jobs, credentials, history) |
