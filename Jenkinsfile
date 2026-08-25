// =====================================================================================
// Jenkinsfile — SINGLE SOURCE OF TRUTH for this pipeline's contract.
// If you change anything about how this pipeline behaves, change it HERE.
//
// What this pipeline does:
//   1. Launches an ephemeral Docker agent (Verify stage) to prove the on-demand
//      agent model + host Docker socket work.
//   2. Checks out the selected GitHub branch.
//   3. Builds an nginx-based static-site image, substituting IMAGE_TAG and
//      DOCKERHUB_USER placeholders in index.html via Docker ARG → sed.
//   4. Pushes the image to Docker Hub, tagged per the convention below.
//
// Architecture: on-demand Docker agents. The Jenkins controller runs persistently;
// agents are ephemeral containers launched per-stage via the Docker Pipeline plugin
// and torn down when each stage finishes. No idle containers between builds.
//
// Container naming convention (also used as the Docker image tag):
//   <branch>-<environment>-<YYYYMMDD>-<short-sha>
//   Example: main-dev-20260825-843b924
//
// Final pushed image:
//   <dockerhub-user>/<dockerhub-image>:<branch>-<environment>-<YYYYMMDD>-<short-sha>
//
// Parameters (all declared here — DO NOT also enable "This project is parameterized"
// in the Jenkins UI or the job will fail with duplicate-parameter errors):
//   BRANCH        — Git Parameter (PT_BRANCH), dropdown is populated dynamically from
//                   the GitHub repo. Default: main. Credential required if the repo is
//                   private: github-pat (Username + password, GitHub PAT).
//   ENVIRONMENT   — Choice: dev / staging / prod. Default: dev.
//   DOCKER_IMAGE  — String. Docker Hub repo path WITHOUT the tag. Default:
//                   bayajidph/jenkins-poc. The user (org) segment is extracted from
//                   before the first "/" and used to substitute DOCKERHUB_USER.
//   GIT_REPO      — String. GitHub repo URL to checkout. Default:
//                   https://github.com/bayajidph/jenkins-poc.git.
//
// Required Jenkins credentials (add via Manage Jenkins → Credentials):
//   github-pat      — Username with password, GitHub PAT (only needed for private repos).
//   dockerhub-creds — Username with password, Docker Hub username + Docker Hub PAT.
//                     IMPORTANT: create these via the Jenkins UI. Pasting the value
//                     through a bash heredoc + --data-urlencode has been observed to
//                     inject ANSI escape codes into the stored value, which surfaces
//                     later as "unknown: malformed HTTP Authorization header" at push.
//
// Required Jenkins plugins:
//   git (default), pipeline (default), credentials-binding (default),
//   plain-credentials (default), Docker Pipeline (docker-workflow),
//   Git Parameter (git-parameter).
//
// First-build gotchas (these always hit on a fresh job — they are NOT bugs):
//   1. "script not yet approved for use" — fix at
//      Manage Jenkins → In-process Script Approval → Approve each pending hash,
//      or run this in the script console once:
//          import org.jenkinsci.plugins.scriptsecurity.scripts.*
//          def sa = ScriptApproval.get()
//          sa.pendingScripts.each { sa.approveScript(it.hash) }
//          sa.save()
//      Then click Build with Parameters again.
//   2. The first build of each stage downloads jenkins/agent:latest-jdk17 (~700 MB)
//      and pulls nginx:alpine during Build. Subsequent builds reuse the cache.
//
// docker-compose.yml must run Jenkins as root with /var/run/docker.sock bind-mounted
// and jenkins_home as a named volume. See docker-compose.yml in this repo.
// =====================================================================================

pipeline {
    agent none

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    parameters {
        // Git Parameter — fetches ALL branches from the GitHub repo dynamically.
        // This requires the "Git Parameter" plugin to be installed.
        gitParameter(
            name: 'BRANCH',
            type: 'PT_BRANCH',
            defaultValue: 'main',
            selectedValue: 'NONE',
            sortMode: 'ASCENDING_SMART',
            description: 'Select a branch to build (fetches all from GitHub)'
        )
        choice(
            name: 'ENVIRONMENT',
            choices: ['dev', 'staging', 'prod'],
            description: 'Target environment'
        )
        string(
            name: 'DOCKER_IMAGE',
            defaultValue: 'bayajidph/jenkins-poc',
            description: 'Docker Hub image (without tag)'
        )
        string(
            name: 'GIT_REPO',
            defaultValue: 'https://github.com/bayajidph/jenkins-poc.git',
            description: 'GitHub repo URL'
        )
    }

    environment {
        DATE_TAG       = sh(script: "date +%Y%m%d",               returnStdout: true).trim()
        SHORT_HASH     = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
        CONTAINER_NAME = "${params.BRANCH}-${params.ENVIRONMENT}-${DATE_TAG}-${SHORT_HASH}"
        FULL_IMAGE     = "${params.DOCKER_IMAGE}:${CONTAINER_NAME}"
    }

    stages {

        // STAGE 0 — Automated test: prove the agent-on-demand model works.
        stage('Verify Agents (Test)') {
            agent {
                docker {
                    image 'jenkins/agent:latest-jdk17'
                    args '-v /var/run/docker.sock:/var/run/docker.sock --network jenkins_net'
                }
            }
            steps {
                echo "=== AGENT LIFECYCLE TEST START ==="
                echo ""
                echo "--- (1) Containers running BEFORE this stage's agent ---"
                sh 'docker ps --format "table {{.Names}}\\t{{.Image}}\\t{{.Status}}"'
                echo ""
                echo "--- (2) Containers running WITH this stage's agent included ---"
                sh '''
                sleep 2
                docker ps --format "table {{.Names}}\\t{{.Image}}\\t{{.Status}}"
                echo ""
                echo "--- (3) THIS container's identity ---"
                echo "Hostname:    $(hostname)"
                echo "Container:   $(cat /etc/hostname)"
                echo "User:        $(whoami)"
                echo "Workspace:   $(pwd)"
                echo ""
                echo "--- (4) Docker socket reachable from agent ---"
                docker version --format 'Server: {{.Server.Version}}' || echo "DOCKER SOCKET NOT MOUNTED"
                echo ""
                echo "--- (5) JNLP handshake evidence ---"
                echo "JENKINS_URL=${JENKINS_URL:-<not set>}"
                echo "JENKINS_NODE_NAME=${JENKINS_NODE_NAME:-<not set>}"
                echo "JENKINS_SECRET=${JENKINS_SECRET:+<redacted>}"
                '''
                echo ""
                echo "=== AGENT LIFECYCLE TEST END ==="
            }
        }

        stage('Checkout') {
            agent {
                docker {
                    image 'jenkins/agent:latest-jdk17'
                    args '-v /var/run/docker.sock:/var/run/docker.sock --network jenkins_net'
                }
            }
            steps {
                echo "Checkout branch: ${params.BRANCH} from ${params.GIT_REPO}"
                checkout([$class: 'GitSCM',
                    branches: [[name: "*/${params.BRANCH}"]],
                    userRemoteConfigs: [[
                        url: params.GIT_REPO,
                        credentialsId: 'github-pat'
                    ]]
                ])
            }
        }

        stage('Build') {
            agent {
                docker {
                    image 'jenkins/agent:latest-jdk17'
                    args '-v /var/run/docker.sock:/var/run/docker.sock --network jenkins_net'
                }
            }
            steps {
                echo "Building image: ${env.FULL_IMAGE}"
                script {
                    env.DOCKERHUB_USER_REPO = params.DOCKER_IMAGE.split('/')[0]
                }
                sh '''
                    docker build \
                        --build-arg IMAGE_TAG=${CONTAINER_NAME} \
                        --build-arg DOCKERHUB_USER=${DOCKERHUB_USER_REPO} \
                        -t ${FULL_IMAGE} .
                '''
            }
        }

        stage('Push to Docker Hub') {
            agent {
                docker {
                    image 'jenkins/agent:latest-jdk17'
                    args '-v /var/run/docker.sock:/var/run/docker.sock --network jenkins_net'
                }
            }
            steps {
                echo "Pushing image: ${env.FULL_IMAGE}"
                withCredentials([usernamePassword(
                    credentialsId: 'dockerhub-creds',
                    usernameVariable: 'DOCKER_USER',
                    passwordVariable: 'DOCKER_PASS'
                )]) {
                    sh '''
                        echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
                        docker push ${FULL_IMAGE}
                        docker logout
                    '''
                }
            }
        }
    }

    post {
        success { echo "Pushed: ${env.FULL_IMAGE}" }
        failure { echo "Build failed for ${params.BRANCH}/${params.ENVIRONMENT}" }
        cleanup {
            sh "docker rmi ${env.FULL_IMAGE} || true"
        }
    }
}