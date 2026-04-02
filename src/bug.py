// In your Jenkinsfile, locate the 'Test' stage and modify it as follows:
stage('Test') {
    steps {
        script {
            // Option 1: Ensure python3 is installed (assuming Debian/Ubuntu agent)
            // This checks if python3 exists and installs if not.
            sh '''
                if ! command -v python3 &> /dev/null
                then
                    echo "python3 not found, installing..."
                    sudo apt-get update && sudo apt-get install -y python3
                else
                    echo "python3 is already installed."
                fi
            '''
            
            // Option 2 (If you use a Docker agent for your pipeline, which is highly recommended for consistent environments):
            // Replace 'agent any' or 'agent { node { label 'your-node-label' } }' 
            // with a Docker agent definition like this at the top of your Jenkinsfile
            /*
            pipeline {
                agent {
                    docker {
                        image 'python:3.9-slim-buster' // Use a Python image that includes python3
                        args '-u root' // Might be needed for some operations, but be mindful of security
                    }
                }
                stages {
                    // ... other stages ...
                    stage('Test') {
                        steps {
                            sh 'python src/bug.py' // Note: 'python' often points to python3 in Docker images
                        }
                    }
                }
            }
            */

            // After ensuring python3 is available, run the test script
            sh 'python3 src/bug.py'
        }
    }
}