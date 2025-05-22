#!/bin/bash

# GenAI Gateway Workshop Deployment Script
# This script handles the creation, update, and deletion of workshop resources

set -e  # Exit immediately if a command exits with a non-zero status

STACK_OPERATION=$1
# Convert operation to lowercase for case-insensitive comparison
STACK_OPERATION_LOWER=$(echo "$STACK_OPERATION" | tr '[:upper:]' '[:lower:]')
REPO_DIR="genai-gateway"
CURRENT_DIR=$(pwd)

echo "Starting operation: $STACK_OPERATION (converted to: $STACK_OPERATION_LOWER for processing)"

# Function to check if required tools are installed
check_prerequisites() {
    echo "Checking prerequisites..."
    
    # Check Docker CLI
    if ! command -v docker &> /dev/null; then
        echo "Error: Docker CLI is not installed or not in PATH"
        exit 1
    fi
    echo "✓ Docker CLI is installed"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        echo "Error: AWS CLI is not installed or not in PATH"
        exit 1
    fi
    echo "✓ AWS CLI is installed"
    
    # Check Terraform CLI
    if ! command -v terraform &> /dev/null; then
        echo "Error: Terraform CLI is not installed or not in PATH"
        exit 1
    fi
    echo "✓ Terraform CLI is installed"
    
    # Check yq utility and version
    if ! command -v yq &> /dev/null; then
        echo "Error: yq utility is not installed or not in PATH"
        exit 1
    fi
    
    YQ_VERSION=$(yq --version | awk '{print $NF}')
    if [[ "$YQ_VERSION" != "v4.40.5" ]]; then
        echo "Error: yq version v4.40.5 is required, but found $YQ_VERSION"
        exit 1
    fi
    echo "✓ yq utility v4.40.5 is installed"
}

# Function to clone the GenAI Gateway repository
clone_repository() {
    echo "Cloning GenAI Gateway repository..."
    if [ -d "$REPO_DIR" ]; then
        echo "Repository directory already exists, using existing clone"
    else
        git clone https://github.com/aws-samples/genai-gateway.git "$REPO_DIR"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to clone repository"
            exit 1
        fi
    fi
    cd "$REPO_DIR"
}

# Function to setup environment configuration
setup_environment() {
    echo "Setting up environment configuration..."
    
    # Copy template environment file if it doesn't exist
    if [ ! -f ".env" ]; then
        cp .env.template .env
        if [ $? -ne 0 ]; then
            echo "Error: Failed to copy .env.template to .env"
            exit 1
        fi
        echo "Created .env file from template"
    else
        echo "Using existing .env file"
    fi
    
    # Note: We don't need to create the S3 bucket - the deploy.sh script handles that
}

# Function to deploy the GenAI Gateway
deploy_genai_gateway() {
    echo "Deploying GenAI Gateway..."
    
    # Check if we're running in Workshop Studio environment
    if [ "$IS_WORKSHOP_STUDIO_ENV" == "yes" ]; then
        echo "Running in Workshop Studio environment"
        echo "Participant Role ARN: $PARTICIPANT_ROLE_ARN"
        echo "Participant Assumed Role ARN: $PARTICIPANT_ASSUMED_ROLE_ARN"
        echo "Assets Bucket Name: $ASSETS_BUCKET_NAME"
        echo "Assets Bucket Prefix: $ASSETS_BUCKET_PREFIX"
    fi
    
    # Run the deploy script
    chmod +x deploy.sh
    ./deploy.sh
    
    if [ $? -ne 0 ]; then
        echo "Error: Deployment failed"
        exit 1
    fi
    
    # Capture and store Terraform outputs
    if [ -d "litellm-terraform-stack" ]; then
        echo "Capturing Terraform outputs..."
        cd litellm-terraform-stack
        
        # Create outputs directory in assets bucket if running in Workshop Studio
        if [ "$IS_WORKSHOP_STUDIO_ENV" == "yes" ] && [ ! -z "$ASSETS_BUCKET_NAME" ] && [ ! -z "$ASSETS_BUCKET_PREFIX" ]; then
            terraform output -json > /tmp/tf_outputs.json
            
            # Create a markdown file with outputs
            cat > /tmp/workshop-outputs.md << EOF
# GenAI Gateway Workshop Outputs

## API Endpoints
- Gateway API: $(jq -r '.api_endpoint.value // "N/A"' /tmp/tf_outputs.json)
- Admin UI: $(jq -r '.admin_ui_url.value // "N/A"' /tmp/tf_outputs.json)

## Resources
- ECS Cluster: $(jq -r '.ecs_cluster_name.value // "N/A"' /tmp/tf_outputs.json)
- RDS Instance: $(jq -r '.rds_instance_id.value // "N/A"' /tmp/tf_outputs.json)
EOF
            
            # Upload to S3 bucket
            aws s3 cp /tmp/workshop-outputs.md s3://${ASSETS_BUCKET_NAME}/${ASSETS_BUCKET_PREFIX}workshop-outputs.md
            echo "Workshop outputs saved to s3://${ASSETS_BUCKET_NAME}/${ASSETS_BUCKET_PREFIX}workshop-outputs.md"
        fi
        
        cd ..
    fi
    
    echo "Deployment completed successfully"
}

# Function to undeploy the GenAI Gateway
undeploy_genai_gateway() {
    echo "Undeploying GenAI Gateway..."
    
    # Run the undeploy script
    chmod +x undeploy.sh
    ./undeploy.sh
    
    if [ $? -ne 0 ]; then
        echo "Error: Undeployment failed"
        exit 1
    fi
    
    echo "Undeployment completed successfully"
}

# Main script execution
check_prerequisites

if [[ "$STACK_OPERATION_LOWER" == "create" || "$STACK_OPERATION_LOWER" == "update" ]]; then
    clone_repository
    setup_environment
    deploy_genai_gateway
    
    # Return to the original directory
    cd "$CURRENT_DIR"
    
elif [ "$STACK_OPERATION_LOWER" == "delete" ]; then
    clone_repository
    undeploy_genai_gateway
    
    # Return to the original directory
    cd "$CURRENT_DIR"
    
else
    echo "Invalid stack operation: $STACK_OPERATION"
    echo "Valid operations are: create, update, delete (case insensitive)"
    exit 1
fi

echo "Operation $STACK_OPERATION completed"
