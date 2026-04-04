pipeline {
        agent {
            // ... (your existing agent configuration)
            tools {
                python 'Python3.9' // Replace 'Python3.9' with the name of your Python 3 installation configured in Jenkins
            }
        }
        stages {
            // ... other stages
            stage('Test') {
                steps {
                    script {
                        // Limit virtual memory to 2GB and resident memory to 1GB for the Python script
                        // This helps prevent the script from consuming excessive memory and crashing the Jenkins agent.
                        // The actual values (in KB) should be tuned based on expected script memory usage.
                        sh 'ulimit -v 2097152 -m 1048576; python3 src/bug.py'
                    }
                }
            }
        }
    }