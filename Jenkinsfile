// =====================================================================================
// Jenkinsfile — TWO-AGENT MODEL (always-on compose services)
//
// Architecture: persistent agents defined in docker-compose.yml. The Jenkins
// controller runs persistently, and so do the two agents — agent-build and
// agent-push. They connect to the controller over JNLP at first boot using
// JENKINS_URL / JENKINS_SECRET / JENKINS_AGENT_NAME env vars set in compose.
// There is no per-stage container spin-up cost; stages run on whichever agent
// matches the requested label.
//
// Agent routing:
//   - agent { label 'build' } -> jenkins-agent-build container
//                                (Checkout + Build stages)
//   - agent { label 'push'  } -> jenkins-agent-push container
//                                (Push to Docker Hub stage)
//
// Both agents run the same custom image (jenkins-agent-with-docker built from
// Dockerfile.agent), and both share the host's Docker engine through
// /var/run/docker.sock (Docker-out-of-Docker), so docker build / docker push
// inside the agent actually execute on the host daemon.
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
//   plain-credentials (default), Git Parameter (git-parameter).
//
// Agent image (custom — see Dockerfile.agent):
//   Built once with `docker build -f Dockerfile.agent -t
//   jenkins-agent-with-docker:latest-jdk17 .` and reused by both services in
//   docker-compose.yml. The image includes the docker CLI so the agents can
//   run docker build / docker push via the host's Docker socket.
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
//   2. Both agents must be online (Manage Jenkins → Nodes) before the first
//      build. If they show up as offline, the JENKINS_SECRET in .env (used by
//      docker-compose.yml) does not match the secret the controller issued.
//      See README §3 to re-issue.
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
        // DATE_TAG is the only thing safe to compute at the controller level —
        // it's a pure shell call. SHORT_HASH, CONTAINER_NAME, and FULL_IMAGE
        // depend on a git repo existing, so they are computed inside the
        // Checkout stage after checkout() has run. Computing them here would
        // either error (no repo on controller) or produce an empty SHORT_HASH,
        // resulting in a tag like "main-dev-20260825-" (empty trailing segment)
        // which breaks `docker push`.
        DATE_TAG = sh(script: "date +%Y%m%d", returnStdout: true).trim()
    }

    stages {

        // ============================================================
        // AGENT 1 — agent-build (persistent)
        // Does everything BUILD-related: Checkout + Build.
        // Runs on the always-on jenkins-agent-build container (label: build).
        // ============================================================
        stage('Build & Package') {
            agent {
                label 'build'
            }
            stages {

                stage('Checkout') {
                    steps {
                        echo "Checkout branch: ${params.BRANCH} from ${params.GIT_REPO}"
                        checkout([$class: 'GitSCM',
                            branches: [[name: "*/${params.BRANCH}"]],
                            userRemoteConfigs: [[
                                url: params.GIT_REPO,
                                credentialsId: 'github-pat'
                            ]]
                        ])
                        script {
                            // Compute the unique image tag here, AFTER checkout,
                            // so git rev-parse has a real repo to read from.
                            env.SHORT_HASH         = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
                            env.CONTAINER_NAME     = "${params.BRANCH}-${params.ENVIRONMENT}-${DATE_TAG}-${env.SHORT_HASH}"
                            env.FULL_IMAGE         = "${params.DOCKER_IMAGE}:${env.CONTAINER_NAME}"
                            env.DOCKERHUB_USER_REPO = params.DOCKER_IMAGE.split('/')[0]
                            echo "Resolved image tag: ${env.FULL_IMAGE}"
                        }
                    }
                }

                stage('Build') {
                    steps {
                        echo "Building image: ${env.FULL_IMAGE}"
                        // DOCKERHUB_USER_REPO was already resolved in the Checkout stage.
                        sh '''
                            docker build \
                                --build-arg IMAGE_TAG=${CONTAINER_NAME} \
                                --build-arg DOCKERHUB_USER=${DOCKERHUB_USER_REPO} \
                                -t ${FULL_IMAGE} .
                        '''
                    }
                }
            }
            post {
                always {
                    echo "build stage finished on agent-build (agent stays online)"
                }
            }
        }

        // ============================================================
        // AGENT 2 — agent-push (persistent)
        // Does everything PUSH-related: Docker Hub authentication + push.
        // Runs on the always-on jenkins-agent-push container (label: push).
        // ============================================================
        stage('Push to Docker Hub') {
            agent {
                label 'push'
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
                        # No `docker logout` here: withCredentials already scopes
                        # DOCKER_USER/DOCKER_PASS to this step. Any failure in
                        # logout would mask a successful push.
                    '''
                }
            }
            post {
                always {
                    echo "push stage finished on agent-push (agent stays online)"
                }
            }
        }
    }

    post {
        success { echo "Pushed: ${env.FULL_IMAGE}" }
        failure { echo "Build failed for ${params.BRANCH}/${params.ENVIRONMENT}" }
    }
}
