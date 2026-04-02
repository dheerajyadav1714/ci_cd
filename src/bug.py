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
                        // Now 'python3' should be found via the tool definition
                        sh 'python3 src/bug.py'
                    }
                }
            }
        }
    }