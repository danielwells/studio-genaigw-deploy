#!/bin/bash

# GenAI Gateway Workshop Deployment Script
# This script handles the creation, update, and deletion of workshop resources

set -e  # Exit immediately if a command exits with a non-zero status

STACK_OPERATION=$1
REPO_DIR="genai-gateway"
CURRENT_DIR=$(pwd)

echo "Starting operation: $STACK_OPERATION"

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

# Function to generate a globally unique S3 bucket name
generate_unique_bucket_name() {
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local region=$(aws configure get region)
    if [ -z "$region" ]; then
        region="us-east-1"
    fi
    local timestamp=$(date +%Y%m%d%H%M%S)
    echo "genai-gateway-tf-state-${account_id}-${region}-${timestamp}"
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
    fi
    
    # Generate a unique S3 bucket name for Terraform state
    TERRAFORM_S3_BUCKET_NAME=$(generate_unique_bucket_name)
    echo "Generated unique S3 bucket name: $TERRAFORM_S3_BUCKET_NAME"
    
    # Update the .env file with the unique bucket name
    sed -i "s/^TERRAFORM_S3_BUCKET_NAME=.*/TERRAFORM_S3_BUCKET_NAME=\"$TERRAFORM_S3_BUCKET_NAME\"/" .env
    
    # Create the S3 bucket if it doesn't exist
    if ! aws s3api head-bucket --bucket "$TERRAFORM_S3_BUCKET_NAME" 2>/dev/null; then
        echo "Creating S3 bucket for Terraform state: $TERRAFORM_S3_BUCKET_NAME"
        aws s3api create-bucket --bucket "$TERRAFORM_S3_BUCKET_NAME" --region $(aws configure get region)
        
        # Enable versioning on the bucket
        aws s3api put-bucket-versioning --bucket "$TERRAFORM_S3_BUCKET_NAME" --versioning-configuration Status=Enabled
    else
        echo "S3 bucket already exists: $TERRAFORM_S3_BUCKET_NAME"
    fi
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
    
    # Get the Terraform S3 bucket name from .env file
    TERRAFORM_S3_BUCKET_NAME=$(grep TERRAFORM_S3_BUCKET_NAME .env | cut -d '"' -f 2)
    
    if [ -n "$TERRAFORM_S3_BUCKET_NAME" ]; then
        echo "Emptying and deleting Terraform state S3 bucket: $TERRAFORM_S3_BUCKET_NAME"
        
        # Empty the bucket
        aws s3 rm "s3://$TERRAFORM_S3_BUCKET_NAME" --recursive
        
        # Delete the bucket
        aws s3api delete-bucket --bucket "$TERRAFORM_S3_BUCKET_NAME"
    fi
    
    echo "Undeployment completed successfully"
}

# Main script execution
check_prerequisites

if [[ "$STACK_OPERATION" == "create" || "$STACK_OPERATION" == "update" ]]; then
    clone_repository
    setup_environment
    deploy_genai_gateway
    
    # Return to the original directory
    cd "$CURRENT_DIR"
    
elif [ "$STACK_OPERATION" == "delete" ]; then
    clone_repository
    undeploy_genai_gateway
    
    # Return to the original directory
    cd "$CURRENT_DIR"
    
else
    echo "Invalid stack operation: $STACK_OPERATION"
    echo "Valid operations are: create, update, delete"
    exit 1
fi

echo "Operation $STACK_OPERATION completed"
