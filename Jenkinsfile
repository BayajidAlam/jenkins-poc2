// =====================================================================================
// Jenkinsfile — TWO-AGENT MODEL (on-demand Docker containers)
//   - build-agent : Checkout + Build (all build-related stages) — one ephemeral container
//   - push-agent  : Push to Docker Hub (all push-related stages) — one ephemeral container
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
// Agent image (custom — see Dockerfile.agent):
//   We do NOT use the upstream `jenkins/agent:latest-jdk17` because that image
//   has no docker CLI. Our pipeline runs `docker build` and `docker push`
//   inside the agent (DooD via /var/run/docker.sock), so we need a docker CLI
//   in the agent. Build the custom image once with:
//       docker build -f Dockerfile.agent -t jenkins-agent-with-docker:latest-jdk17 .
//   The custom image is ~520 MB and is reused across all builds.
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
//   2. The first build pulls jenkins-agent-with-docker:latest-jdk17 (~520 MB,
//      built locally from Dockerfile.agent) and nginx:alpine during Build.
//      Subsequent builds reuse the cache.
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
        // AGENT 1 — build-agent
        // Does everything BUILD-related: Checkout + Build.
        // One ephemeral Docker container runs both sub-stages, then is torn down.
        // ============================================================
        stage('Build & Package') {
            agent {
                docker {
                    image 'jenkins-agent-with-docker:latest-jdk17'
                    args '-v /var/run/docker.sock:/var/run/docker.sock --network jenkins_net'
                }
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
                    echo "build-agent finished — container will be torn down"
                }
            }
        }

        // ============================================================
        // AGENT 2 — push-agent
        // Does everything PUSH-related: Docker Hub authentication + push.
        // One ephemeral Docker container, single stage, then torn down.
        // ============================================================
        stage('Push to Docker Hub') {
            agent {
                docker {
                    image 'jenkins-agent-with-docker:latest-jdk17'
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
                        # No `docker logout` here: withCredentials already scopes
                        # DOCKER_USER/DOCKER_PASS to this step, and the agent is
                        # torn down immediately after the stage ends. Any failure
                        # in logout would mask a successful push.
                    '''
                }
            }
            post {
                always {
                    echo "push-agent finished — container will be torn down"
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
