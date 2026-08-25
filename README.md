# Jenkins POC — CI/CD for a static site


<img width="1536" height="900" alt="ChatGPT Image Aug 20, 2026, 06_36_19 PM" src="https://github.com/user-attachments/assets/46c4b960-aae5-4489-bcc7-26c593595158" />


The code is just an `index.html`. Jenkins checks it out, builds/tests/packages it, and on deploy runs an `nginx:alpine` container that serves the file on a host port. Every deploy produces a uniquely-named container and a bind-mounted directory under `/var/jenkins-deploy/`, so old builds are kept until the cleanup stage prunes them.

This README is **fully self-contained** — every file you need is pasted inline below. From a bare host with only Docker installed, you can bootstrap the whole thing by:

- Copying the three files from "The files" section into a directory.
- Pushing that directory to a GitHub repo.
- Following "Start Jenkins" → "Run the pipeline".

---

## 1. The files

Drop these three files into a directory (this repo already has them, but they're reproduced here so you can bootstrap from scratch on a fresh host).

### Repo layout

```
jenkins-poc/
├── Jenkinsfile          # Pipeline definition
├── docker-compose.yml   # Jenkins controller (port 8080/50000)
└── index.html           # The static site that gets deployed
```

### `index.html`

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Hello World — CI/CD</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
      background: linear-gradient(135deg, #0f172a, #1e293b);
      color: #f8fafc;
    }
    .card {
      text-align: center;
      padding: 2.5rem 3rem;
      border-radius: 1rem;
      background: rgba(255,255,255,0.05);
      box-shadow: 0 10px 30px rgba(0,0,0,0.3);
    }
    h1 { font-size: 2.5rem; margin: 0 0 0.5rem; }
    p  { opacity: 0.7; margin: 0; }
    code {
      display: inline-block;
      margin-top: 1rem;
      padding: 0.25rem 0.5rem;
      background: rgba(0,0,0,0.3);
      border-radius: 0.25rem;
      font-size: 0.9rem;
    }
  </style>
</head>
<body>
  <div class="card">
    <h1>Hello, World! 👋</h1>
    <p>Built, tested, packaged & deployed by Jenkins.</p>
    <p style="margin-top:0.75rem;font-size:0.9rem;opacity:0.85;">🚀 <strong>Build #1</strong> — first deploy</p>
    <code>YOUR-GITHUB-USER/jenkins-poc</code>
  </div>
</body>
</html>
```

> Replace `YOUR-GITHUB-USER` with your GitHub username.

### `docker-compose.yml`

```yaml
services:
  jenkins:
    image: jenkins/jenkins:lts-jdk17
    container_name: jenkins
    restart: unless-stopped
    user: root
    ports:
      - "8080:8080"   # Jenkins web UI
      - "50000:50000" # Jenkins agent (JNLP) port
      # Port 8088 is exposed by the Deploy stage's nginx container directly
      # on the host. We deliberately do NOT pre-map it here, because the
      # Jenkins container shares the host network namespace via the
      # docker socket and would otherwise steal the port.
    volumes:
      - jenkins_home:/var/jenkins_home
      # Mount the host Docker socket so the Deploy stage can launch nginx.
      - /var/run/docker.sock:/var/run/docker.sock
      # Mount the host docker CLI so the pipeline can run docker commands.
      # (The jenkins image doesn't include docker-cli; this lets the Deploy
      #  stage launch the nginx container using the host's docker binary.)
      - /usr/bin/docker:/usr/bin/docker:ro
      # Bind-mount the persistent deploy directory from the host so the
      # pipeline's `cp` and nginx's `-v` end up pointing at the SAME
      # directory. Without this, the Jenkins container has its own
      # /var/jenkins-deploy namespace, and the host's nginx mount would
      # still serve stale files.
      - /var/jenkins-deploy:/var/jenkins-deploy
    environment:
      - JAVA_OPTS=-Djenkins.install.runSetupWizard=true -Dhudson.security.csrf.mintcrumbdisabled=true -Dhudson.security.csrf.requestfield=
      # CSRF disabled because Jenkins sits behind a reverse proxy that may
      # strip/alter the crumb header. Webhooks from GitHub still work
      # (they POST without a crumb anyway).

volumes:
  jenkins_home:
```

### `Jenkinsfile`

```groovy
pipeline {
    agent any

    parameters {
        choice(name: 'BRANCH', choices: ['main', 'develop', 'feature/*'], description: 'Git branch')
        choice(name: 'ENV',    choices: ['dev', 'staging', 'prod'],      description: 'Target environment')
    }

    environment {
        REPO_URL    = 'https://github.com/YOUR-GITHUB-USER/jenkins-poc.git'
        DEPLOY_ROOT = '/var/jenkins-deploy'
    }

    stages {
        stage('application') {
            steps {
                dir('application') {
                    checkout([$class: 'GitSCM',
                        branches: [[name: "*/${BRANCH}"]],
                        userRemoteConfigs: [[
                            credentialsId: 'github-pat',
                            url: "${REPO_URL}"
                        ]]
                    ])
                }
            }
        }

        stage('Build') {
            steps {
                sh '''
                    cd application
                    mkdir -p build
                    date -u +'%Y-%m-%dT%H:%M:%SZ' > build/build-info.txt
                    echo "Built from commit $(git rev-parse --short HEAD)" >> build/build-info.txt
                    echo "Branch: ${BRANCH}" >> build/build-info.txt
                    echo "Env:    ${ENV}"    >> build/build-info.txt
                '''
            }
        }

        stage('Test') {
            steps {
                sh '''
                    cd application
                    test -f index.html
                    grep -q "Hello World" index.html
                '''
            }
        }

        stage('Package') {
            steps {
                sh 'tar -czf site.tar.gz -C application index.html'
                archiveArtifacts artifacts: 'site.tar.gz', fingerprint: true
            }
        }

        stage('Deploy') {
            steps {
                script {
                    def safeBranch = BRANCH.replaceAll('/', '-')
                    def envPort = [dev: '8088', staging: '8089', prod: '8090']
                    def port = envPort[ENV]

                    def ts  = sh(returnStdout: true, script: "date -u +'%Y%m%dT%H%M%SZ'").trim()
                    def sha = sh(returnStdout: true, script: "git -C application rev-parse --short HEAD").trim()

                    env.SITE_NAME = "${safeBranch}-${ENV}-${ts}-${sha}"
                    env.SITE_DIR  = "${DEPLOY_ROOT}/${env.SITE_NAME}"
                    env.PORT      = port

                    echo "Site: ${env.SITE_NAME} on port ${env.PORT}"
                }

                sh '''#!/bin/bash
                    set -eux

                    # Discover host gateway (Jenkins container has its own net ns).
                    HEX_GW=$(awk 'NR>1 && $2=="00000000" {print $3}' /proc/net/route | head -1 | tr -d ' ')
                    HOST_IP=$(printf '%d.%d.%d.%d\\n' "0x${HEX_GW:6:2}" "0x${HEX_GW:4:2}" "0x${HEX_GW:2:2}" "0x${HEX_GW:0:2}")

                    mkdir -p "${SITE_DIR}"
                    cp -f application/index.html "${SITE_DIR}/"

                    # Prune older <branch>-<env>-* containers before starting the new one.
                    docker ps -a --format '{{.Names}}' \
                      | grep "^$(echo ${SITE_NAME} | sed 's/-[0-9].*//')-" \
                      | grep -v "^${SITE_NAME}$" \
                      | xargs -r docker rm -f || true

                    docker run -d \
                      --name "${SITE_NAME}" \
                      --restart unless-stopped \
                      -p "${PORT}:80" \
                      -v "${SITE_DIR}:/usr/share/nginx/html:ro" \
                      nginx:alpine

                    sleep 3
                    curl -fsS "http://${HOST_IP}:${PORT}/" | grep -q "Hello World"
                    echo "Live at http://${HOST_IP}:${PORT}/"
                '''
            }
        }

        stage('Cleanup') {
            steps {
                sh '''
                    SAFE_PREFIX=$(echo "${SITE_NAME}" | sed 's/-[0-9]\\{8\\}T.*//')
                    find "${DEPLOY_ROOT}" -maxdepth 1 -type d \
                      -name "${SAFE_PREFIX}-*" \
                      ! -name "${SITE_NAME}" \
                      -exec rm -rf {} +
                '''
            }
        }
    }

    post {
        success { echo "Done — ${env.SITE_NAME} on port ${env.PORT}" }
        failure { echo 'Failed. Check logs.' }
        always  { cleanWs() }
    }
}
```

> Replace `YOUR-GITHUB-USER` in the `REPO_URL` line with your GitHub username.

---

## 2. Push to GitHub

The pipeline checks out the repo from GitHub, so the files must be in a GitHub repo before Jenkins can build them.

### One-time: create the repo

- Go to `https://github.com/new`.
- Repository name: `jenkins-poc`.
- Visibility: Public (simplest) or Private (requires the PAT setup later).
- **Do NOT** initialize with README, .gitignore, or license — we'll push an existing repo.
- Click **Create repository**.

### Push the local files

```bash
cd /path/to/jenkins-poc
git init
git add .
git commit -m "Initial commit: jenkins-poc files"
git branch -M main
git remote add origin https://github.com/YOUR-GITHUB-USER/jenkins-poc.git
git push -u origin main
```

Replace `YOUR-GITHUB-USER` with your GitHub username.

---

## 3. Prerequisites

### What you need on the host

- **OS**: Linux (the Compose file uses Linux bind-mount paths).
- **Docker**: any recent version.
- **Docker Compose plugin**: docker compose
- **Free host ports**:

  | Port | Used by |
  |---|---|
  | `8080` | Jenkins web UI |
  | `50000` | Jenkins JNLP agent |
  | `8088` | Deployed site when `ENV=dev` |
  | `8089` | Deployed site when `ENV=staging` |
  | `8090` | Deployed site when `ENV=prod` |


### Quick check

```bash
docker --version
docker compose version
docker ps
```

You will see like:

<img width="964" height="194" alt="image" src="https://github.com/user-attachments/assets/c8f3cabb-1d28-4b60-8ba3-f2116d9842c7" />

---

## 4. Start Jenkins

### Run the container

```bash
docker compose -f docker-compose.yml up -d
```

> The file is named `docker-compose.yml` (legacy v1 name). Modern Docker Compose v2 still picks it up if you pass it explicitly with `-f`.

<img width="1591" height="190" alt="image" src="https://github.com/user-attachments/assets/dc87c23f-d77b-4d3c-9547-6bfe9758911f" />


### Verify it's up

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Expected:

<img width="1558" height="100" alt="image" src="https://github.com/user-attachments/assets/9525192c-c525-4884-9708-cbac31ab8c13" />


### Get the initial admin password

Either of these works (the password is only printed on first boot):


```bash
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

You will see :

<img width="1399" height="62" alt="image" src="https://github.com/user-attachments/assets/d3c12307-dfa2-440e-ae51-19ac50ede25f" />

Use it to login jenkins

---

## 5. First-time Jenkins setup (browser)

runh `ip addr show` and you will see `eth0` copy the ip from there 

<img width="1365" height="187" alt="image" src="https://github.com/user-attachments/assets/3b009bc9-e895-4dea-ac3b-01f3b4b862a2" />

Here is `10.62.27.156` is the ip. copy it and go to Poridhi lab and select `Load Balancer` from left panel and add like this, and click expose:

<img width="898" height="509" alt="image" src="https://github.com/user-attachments/assets/5c62589d-1224-4bd7-9ce3-a45b5b33a5ca" />

You will get a URL open it on browser tab, you will see
<img width="1907" height="994" alt="image" src="https://github.com/user-attachments/assets/2deb3aea-2d70-4592-bf7d-2da3e2326040" />

put you previously generated password here and click continue; you will see:
<img width="1095" height="931" alt="image" src="https://github.com/user-attachments/assets/35c8ea6f-505a-4cc1-9cc9-ab91e47abb60" />

 Click **Install suggested plugins** (takes a minute or two) and 

<img width="974" height="889" alt="image" src="https://github.com/user-attachments/assets/eaa1f782-d978-4652-8916-4ac88336c437" />
 Create your admin user (username / email / password), then click  `save acontinue`nd 

<img width="982" height="900" alt="image" src="https://github.com/user-attachments/assets/42aff877-e659-4717-b653-ea77bdd9443f" />
finally you will be `Instance Configuration` put your jenkins url here and click `save and finish` 

You should land on the Jenkins dashboard.

<img width="1906" height="983" alt="image" src="https://github.com/user-attachments/assets/c8024807-c15e-4bfb-98c8-782ebeab3191" />

---

## 6. Create the pipeline job

### Step-by-step

Dashboard → **New Item** (top-left).
<img width="1719" height="902" alt="image" src="https://github.com/user-attachments/assets/811e63cb-14e3-4e43-93e0-8984ece124d0" />

Name: `hello-world` (or anything you like).
Type: **Pipeline** → click **OK**.

Now click on `hello-world` and in `General` section select `This project is parameterized`

`Name`: `BRANCH`
`Choices`:
 ` main
  dev
  stag`
  Like this: 
<img width="1311" height="568" alt="image" src="https://github.com/user-attachments/assets/dba18c18-4314-4eb8-b36e-3d2544c18e43" />
Now again click on`add parameter` and andd 

`Name`: `ENV`
`Choices`: 
          `
dev
dev
prod`
<img width="1254" height="518" alt="image" src="https://github.com/user-attachments/assets/df94ad2f-806b-44d5-a6d1-b02816693543" />



Scroll down and In `Pipeline` section select `Pipeline script` and paster your  `Jenkinsfile` copiced earlier;
and select save
<img width="1448" height="735" alt="image" src="https://github.com/user-attachments/assets/a86bc016-dea8-43d0-aac8-88b474d71299" />

## 7. Run the pipeline


Now on `hello-world` select `Build with perameters` select 
`BRANCH`: `main`
`ENv`: `dev`
it will start building

go to poridhi dashboard add one more lb like this and put port `8088`

<img width="931" height="430" alt="image" src="https://github.com/user-attachments/assets/b6097b21-8c7f-46de-9689-653e45e26d75" />

### Parameters

| Parameter | Choices | Default | What it does |
|---|---|---|---|
| `BRANCH` | `main`, `dev`, `steg` | 
| `ENV` | `dev`, `staging`, `prod` |

### ENV → host port mapping

| `ENV` | Host port the site listens on |
|---|---|
| `dev` | **8088** |
| `staging` | **8089** |
| `prod` | **8090** |

### Stages and what each one does

| Stage | What it does |
|---|---|
| **application** | Clones the repo into a workspace subdir `application/`. |
| **Build** | Writes `build/build-info.txt` with timestamp, commit SHA, branch, env. |
| **Test** | Sanity-checks that `index.html` exists and contains "Hello World". |
| **Package** | Tars `index.html` into `site.tar.gz` and archives it as a build artifact. |
| **Deploy** | Copies `index.html` into `/var/jenkins-deploy/<branch>-<env>-<ts>-<sha>/`, removes older containers with the same `<branch>-<env>-` prefix, and `docker run`s an `nginx:alpine` container bound to the chosen host port. Curls the URL to confirm the page is live. |
| **Cleanup** | Deletes older `<branch>-<env>-*` directories under `/var/jenkins-deploy`, keeping only the current one. |

---

## 8. Verify the deployed site

### What the Deploy stage prints

```
Live at http://<host-ip>:8088/](https://6932b4db068c684dd55b0c6d_2246d952.lb.poridhi.io/)
```

### What you should see in a browser

Open `[http://<this-host>:8088/](https://6932b4db068c684dd55b0c6d_2246d952.lb.poridhi.io/)` (or the port for your chosen `ENV`). You should see:

<img width="1916" height="935" alt="image" src="https://github.com/user-attachments/assets/0d545e74-9e05-4f62-a057-8e6a0a8923e7" />


