# Jenkins POC — CI/CD with On-Demand Agents → Docker Hub

A Jenkins pipeline that builds a static nginx site and pushes the resulting Docker
image to Docker Hub. Every parameterized build spins up its own ephemeral Docker
agents (launched by the controller, torn down when the stage finishes) and produces
a uniquely-tagged image.

<img width="1638" height="805" alt="image" src="https://github.com/user-attachments/assets/06d99555-1832-4e47-b0b6-6d308598d15c" />

> **The `Jenkinsfile` is the single source of truth for this pipeline's contract.**
> All parameters, defaults, credential IDs, plugin requirements, naming convention,
> and first-build gotchas are documented in the comment block at the top of
> [`Jenkinsfile`](./Jenkinsfile). This README is only the operator quickstart.

---

## 1. What you get

- Jenkins controller runs persistently as the only service in `docker-compose.yml`.
- Agents are **NOT** declared in Compose. They are launched on-demand per stage by
  the `Jenkinsfile` via the Docker Pipeline plugin. When a stage ends, its agent is
  stopped and removed.
- Agents share the host's Docker engine through the mounted `/var/run/docker.sock`
  (Docker-out-of-Docker pattern), so `docker build` / `docker push` inside an agent
  actually execute on the host daemon.
- Every build is triggered manually via *Build with Parameters* — no webhooks.

### Why two agents?

The pipeline uses **two distinct ephemeral agents** rather than one because:

1. **Credential isolation** — the push-agent handles `dockerhub-creds`. Keeping
   it in a separate container limits the exposure window of those secrets.
2. **Clean Docker login state** — the push-agent logs in to Docker Hub at the
   start of its stage and the agent is torn down when the stage ends. No stale
   auth state lingers between builds.
3. **Independent failure isolation** — a broken build doesn't leave any
   half-configured push state behind, and vice versa.

Image tag format (final Docker Hub push): `<branch>-<environment>-<YYYYMMDD>-<short-sha>`
Example: `main-dev-20260825-843b924`

## 2. Repo layout

```
jenkins-poc/
├── Jenkinsfile          # SINGLE SOURCE OF TRUTH — read the top comment block
├── Dockerfile           # nginx:alpine + sed-substituted placeholders
├── Dockerfile.agent     # Custom Jenkins agent image (jenkins/agent + docker CLI)
├── docker-compose.yml   # Jenkins controller only
├── index.html           # The static site (with IMAGE_TAG_PLACEHOLDER / DOCKERHUB_USER placeholders)
└── README.md            # This file (operator quickstart)
```

## 3. Prerequisites — build the custom agent image FIRST

The upstream `jenkins/agent:latest-jdk17` does **not** ship with the docker CLI,
but our pipeline runs `docker build` and `docker push` *inside* the agent
(Docker-out-of-Docker via `/var/run/docker.sock`). Build the custom agent image
**before** bringing Jenkins up — the pipeline will fail at the first stage
otherwise.

```bash
docker build -f Dockerfile.agent -t jenkins-agent-with-docker:latest-jdk17 .
docker images | grep jenkins-agent-with-docker
```

The custom image is ~520 MB and is reused across all builds.

## 4. Bring Jenkins up

```bash
docker compose up -d
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

You should see `jenkins-controller` listening on `0.0.0.0:8080->8080` and
`0.0.0.0:50000->50000`.

Confirm the host Docker socket is reachable from inside the controller
(this is the #1 first-run failure):

```bash
docker exec jenkins-controller docker version --format '{{.Server.Version}}'
# Expected: prints the host Docker server version, e.g. 29.6.1
```

If you get "permission denied", fix the socket perms:

```bash
sudo chmod 666 /var/run/docker.sock
docker compose restart jenkins
```

Get the initial admin password:

```bash
docker exec jenkins-controller cat /var/jenkins_home/secrets/initialAdminPassword
```

Open `http://<host>:8080`, paste the password, click **Install suggested plugins**,
then create your admin user.

## 5. Install the extra plugins

After first boot, go to **Manage Jenkins → Plugins → Available plugins** and install:

| Plugin | Why |
|---|---|
| **Docker Pipeline** | Lets the `Jenkinsfile` launch `agent { docker { ... } }` blocks |
| **Git Parameter** | Populates the `BRANCH` parameter dynamically from GitHub |

A fresh `lts-jdk17` install already has `git`, `pipeline`, `credentials-binding`,
and `plain-credentials`. Restart Jenkins when prompted.

## 6. Add credentials

Go to **Manage Jenkins → Credentials → (global) → Add Credentials**.

| Credential ID | Kind | Username | Password | Required when |
|---|---|---|---|---|
| `github-pat` | Username with password | your GitHub user | your GitHub PAT (`repo` scope) | repo is private |
| `dockerhub-creds` | Username with password | your Docker Hub user | your Docker Hub PAT | always |

> **Set credentials via the Jenkins UI, not via shell scripts.**
> Pasting a credential value through `bash` heredoc + `--data-urlencode "script@..."`
> into the Jenkins script console has been observed to inject ANSI escape sequences
> into the stored value, surfacing later as
> `Error response from daemon: unknown: malformed HTTP Authorization header` at the
> Push stage. The UI stores the value verbatim.

## 7. Create the pipeline job

Dashboard → **New Item** → name: `app-build-push` → type: **Pipeline** → OK.

- **Do NOT** check *This project is parameterized*. The `Jenkinsfile` declares all
  four parameters itself; doing both creates duplicate-parameter errors and the
  job will fail to load.
- Under **Pipeline**:
  - Definition: **Pipeline script from SCM**
  - SCM: **Git**
  - Repository URL: `https://github.com/bayajidph/jenkins-poc.git` (or your fork)
  - Credentials: select `github-pat` (if your repo is private)
  - Branch: `*/main`
  - Script Path: `Jenkinsfile`
- Click **Save**.

The defaults baked into the `Jenkinsfile` are
`DOCKER_IMAGE=bayajidph/jenkins-poc` and
`GIT_REPO=https://github.com/bayajidph/jenkins-poc.git`. Override them either by
editing the file, or by passing them at build time as parameters — they are
runtime overrides.

## 8. First-build gotchas

Two issues always hit on the first run. They are not bugs — they're Jenkins
safety mechanisms.

### 8.1 Script Approval

The very first build fails with:

```
org.jenkinsci.plugins.scriptsecurity.scripts.UnapprovedUsageException: script not yet approved for use
```

Jenkins' In-process Script Approval blocks Groovy scripts it hasn't seen before.

**Fix:** Go to **Manage Jenkins → In-process Script Approval**. Click **Approve**
for each pending script hash (or use the bulk-approve snippet below). Then click
**Build with Parameters** again.

Bulk approve via the script console (Manage Jenkins → Script Console):

```groovy
import org.jenkinsci.plugins.scriptsecurity.scripts.*
def sa = ScriptApproval.get()
sa.pendingScripts.each { sa.approveScript(it.hash) }
sa.save()
println "Approved ${sa.pendingScripts.size()} scripts"
```

### 8.2 First build is slow

The first build pulls `jenkins-agent-with-docker:latest-jdk17` (~520 MB, built
locally from `Dockerfile.agent` per §3) and `nginx:alpine` during the Build
stage. Subsequent builds reuse the cache and are much faster.

## 9. Run the pipeline

On the job page, click **Build with Parameters**. You see four fields:

| Parameter | Type | Default / placeholder |
|---|---|---|
| `BRANCH` | Git Parameter (dropdown auto-fetched from GitHub) | placeholder `NONE` — you must actively select a branch each build |
| `ENVIRONMENT` | Choice (`dev` / `staging` / `prod`) | `dev` |
| `DOCKER_IMAGE` | String (Docker Hub repo without tag) | `bayajidph/jenkins-poc` |
| `GIT_REPO` | String (GitHub repo URL) | `https://github.com/bayajidph/jenkins-poc.git` |

Click **Build**.

For each stage, an ephemeral agent container is launched and then removed:

```
[Pipeline] withDockerContainer
$ docker run -t -d -u 0:0 -v /var/run/docker.sock:/var/run/docker.sock --network jenkins_net ... jenkins-agent-with-docker:latest-jdk17 cat
... stage body ...
$ docker stop --time=1 <container-id>
$ docker rm -f --volumes <container-id>
[Pipeline] // withDockerContainer
```

The Push stage finishes with:

```
+ docker push <your-dockerhub-user>/<your-image>:<branch>-<env>-<YYYYMMDD>-<sha>
... all layers pushed ...
Pushed: <your-dockerhub-user>/<your-image>:<branch>-<env>-<YYYYMMDD>-<sha>
Finished: SUCCESS
```

### Verify the image on Docker Hub

From any host with Docker installed, substitute your actual values (example
shown for the `main`/`dev` default build of this repo):

```bash
docker pull bayajidph/jenkins-poc:main-dev-20260825-331cd38
docker run --rm -d -p 8088:80 --name verify bayajidph/jenkins-poc:main-dev-20260825-331cd38
curl -s http://localhost:8088 | grep image-tag
# <span class="tag" id="image-tag">main-dev-20260825-331cd38</span>
docker stop verify && docker rm verify
```

The `<span id="image-tag">` value matches the tag, proving the Dockerfile's
`sed` substitution ran end-to-end.

## 10. Stages

See [`Jenkinsfile`](./Jenkinsfile) for the live definition.

| Stage | What it does |
|---|---|
| **Build & Package → Checkout** | Launches a fresh agent and `git clone`s `${params.GIT_REPO}` at `${params.BRANCH}`. After checkout, computes the unique image tag (`${BRANCH}-${ENV}-${YYYYMMDD}-${short-sha}`). |
| **Build & Package → Build** | Same ephemeral agent. Runs `docker build -t ${FULL_IMAGE} .` on the Dockerfile, substituting the IMAGE_TAG and DOCKERHUB_USER placeholders. The `-t` flag does the tagging — no separate `docker tag` step. |
| **Push to Docker Hub** | Launches a *separate* fresh agent, logs in to Docker Hub with `dockerhub-creds`, and pushes the image built by the previous stage. |

Every stage runs in its own ephemeral agent — except Checkout and Build, which
share one agent (the parent `Build & Package` stage). No persistent agents, no
always-on cost.

## 11. Troubleshooting

**First build fails with `script not yet approved for use`** — see §8.1. Approve
scripts at *Manage Jenkins → In-process Script Approval*.

**Push stage fails with `Error response from daemon: Get "https://registry-1.docker.io/v2/": unauthorized`** —
wrong Docker Hub username or password in the `dockerhub-creds` credential.
Verify via the script console:

```groovy
import jenkins.model.*
import com.cloudbees.plugins.credentials.common.*
def found = null
for (c in CredentialsProvider.lookupCredentials(StandardUsernameCredentials.class, Jenkins.instance, null, null)) {
    if (c.id == 'dockerhub-creds') { found = c; break }
}
println "user=${found.username} token=${found.password?.plainText} len=${found.password?.plainText?.length()}"
```

The `len` should equal your token's length, with no escape codes or extra characters.

**Push stage fails with `unknown: malformed HTTP Authorization header`** — the
credential was set through a method that injected stray characters (typically a
bash heredoc piped into the script console). Delete the credential in the UI and
re-add it manually. See §6 warning.

**Checkout stage fails with `Could not find any suitable branch`** — `BRANCH` was
passed a value that doesn't exist in the GitHub repo, or the Git Parameter plugin
failed to fetch branches. Check that `GIT_REPO` is reachable from the Jenkins
controller.

**`BRANCH` dropdown is empty** — the Git Parameter plugin couldn't fetch from
your repo. If the repo is private, the `github-pat` credential is missing or has
wrong scopes (needs `repo`).

**Agent fails to talk to host Docker** — confirm `/var/run/docker.sock` is
mounted into the controller (`docker exec jenkins-controller ls -la /var/run/docker.sock`).
On the host: `chmod 666 /var/run/docker.sock`.
