// Jenkinsfile — CI/CD pipeline with parameterized branch + environment
// Architecture: on-demand Docker agents. The Jenkins controller runs persistently,
// agents are ephemeral containers launched per-stage via the Docker Pipeline plugin.
//
// Container naming convention: branch-environment-date-hash
// Example: feature-x-dev-20260825-a1b2c3

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
        // Naming convention: branch-environment-date-hash
        CONTAINER_NAME = "${params.BRANCH}-${params.ENVIRONMENT}-${DATE_TAG}-${SHORT_HASH}"
        FULL_IMAGE     = "${params.DOCKER_IMAGE}:${CONTAINER_NAME}"
    }

    stages {

        // ============================================================
        //  STAGE 0 — Automated test: prove the agent-on-demand model works.
        // ============================================================
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