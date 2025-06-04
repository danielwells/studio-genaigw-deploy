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

# Function to find existing Terraform state bucket
find_existing_bucket() {
    echo "Finding existing Terraform state bucket..." >&2
    
    # List buckets with the genai-gateway-tf-state prefix
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    echo "DEBUG: Account ID: $account_id" >&2
    
    local buckets=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'genai-gateway-tf-state-${account_id}')].Name" --output text)
    echo "DEBUG: Found buckets: $buckets" >&2
    
    # Check if we found any buckets
    if [ -z "$buckets" ]; then
        echo "Error: No existing Terraform state bucket found" >&2
        exit 1
    fi
    
    # Use the first bucket found (assuming it's the most recent)
    # Trim any whitespace or quotes that might be present
    local bucket=$(echo "$buckets" | head -1 | tr -d "'" | tr -d " ")
    echo "Found existing Terraform state bucket: $bucket" >&2
    echo "DEBUG: Bucket name length: ${#bucket}" >&2
    
    # Return just the bucket name without newline or quotes
    echo -n "$bucket"
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

# Function to update Dockerfiles to use ECR Public Gallery for Python images
update_dockerfiles() {
    echo "Updating Dockerfiles to use ECR Public Gallery for Python images..."
    
    # Authenticate to ECR Public Gallery
    echo "Authenticating to ECR Public Gallery..."
    aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws
    
    # Update middleware Dockerfile
    if [ -f "middleware/Dockerfile" ]; then
        echo "Updating middleware/Dockerfile..."
        sed -i 's|FROM python:3.11-slim|FROM public.ecr.aws/docker/library/python:3.11-slim|g' middleware/Dockerfile
        echo "✓ Updated middleware/Dockerfile to use ECR Public Gallery"
    fi
    
    # Update load testing Dockerfile
    if [ -f "litellm-fake-llm-load-testing-server-terraform/docker/Dockerfile" ]; then
        echo "Updating litellm-fake-llm-load-testing-server-terraform/docker/Dockerfile..."
        sed -i 's|FROM python:3.13-slim|FROM public.ecr.aws/docker/library/python:3.13-slim|g' litellm-fake-llm-load-testing-server-terraform/docker/Dockerfile
        echo "✓ Updated load testing Dockerfile to use ECR Public Gallery"
    fi
    
    echo "Dockerfiles updated to use ECR Public Gallery for Python images"
}

# Function to setup environment configuration for create/update
setup_environment_create() {
    echo "Setting up environment configuration for create/update..."
    
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
    
    # Generate a unique S3 bucket name for Terraform state
    TERRAFORM_S3_BUCKET_NAME=$(generate_unique_bucket_name)
    echo "Generated unique S3 bucket name: $TERRAFORM_S3_BUCKET_NAME"
    
    # Update the .env file with the unique bucket name
    sed -i "s|^TERRAFORM_S3_BUCKET_NAME=.*|TERRAFORM_S3_BUCKET_NAME=\"$TERRAFORM_S3_BUCKET_NAME\"|" .env
    echo "Updated .env file with S3 bucket name"
}

# Function to setup environment configuration for delete
setup_environment_delete() {
    echo "Setting up environment configuration for delete..."
    
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
    
    # Find existing Terraform state bucket
    TERRAFORM_S3_BUCKET_NAME=$(find_existing_bucket)
    echo "DEBUG: Retrieved bucket name: '$TERRAFORM_S3_BUCKET_NAME'"
    echo "DEBUG: Bucket name length: ${#TERRAFORM_S3_BUCKET_NAME}"
    
    # Check if TERRAFORM_S3_BUCKET_NAME exists in .env
    if grep -q "^TERRAFORM_S3_BUCKET_NAME=" .env; then
        echo "DEBUG: Found TERRAFORM_S3_BUCKET_NAME line in .env"
        # Update the existing line
        sed -i "s|^TERRAFORM_S3_BUCKET_NAME=.*|TERRAFORM_S3_BUCKET_NAME=\"$TERRAFORM_S3_BUCKET_NAME\"|" .env
        echo "DEBUG: sed command exit status: $?"
    else
        echo "DEBUG: No TERRAFORM_S3_BUCKET_NAME line found in .env, adding it"
        # Add the line if it doesn't exist
        echo "TERRAFORM_S3_BUCKET_NAME=\"$TERRAFORM_S3_BUCKET_NAME\"" >> .env
    fi
    
    echo "Updated .env file with existing S3 bucket name: $TERRAFORM_S3_BUCKET_NAME"
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
    
    # Update Dockerfiles to use ECR Public Gallery for Python images
    update_dockerfiles
    
    # Run the deploy script
    chmod +x deploy.sh
    ./deploy.sh
    
    if [ $? -ne 0 ]; then
        echo "Error: Deployment failed"
        exit 1
    fi
    
    # Capture Terraform outputs for CloudFormation
    if [ -d "litellm-terraform-stack" ]; then
        echo "Capturing Terraform outputs for CloudFormation..."
        cd litellm-terraform-stack
        
        # Get the outputs as JSON
        terraform output -json > /tmp/tf_outputs.json
        
        # Output the raw Terraform outputs to the log for debugging
        echo "Raw Terraform outputs:"
        terraform output
        echo "JSON Terraform outputs:"
        cat /tmp/tf_outputs.json
        
        # Extract key outputs using the correct output names
        API_ENDPOINT=$(jq -r '.ServiceURL.value // "N/A"' /tmp/tf_outputs.json)
        LITELLM_DASHBOARD_UI=$(jq -r '.ServiceURL.value // "N/A"' /tmp/tf_outputs.json)
        ECS_CLUSTER_NAME=$(jq -r '.LitellmEcsCluster.value // "N/A"' /tmp/tf_outputs.json)
        
        # Extract the RDS database identifier from Terraform state
        RDS_INSTANCE_ID=$(terraform state show 'module.base.aws_db_instance.database' | grep -E "^    identifier[ ]+=" | awk -F= '{print $2}' | tr -d ' "')
        if [ -z "$RDS_INSTANCE_ID" ]; then
            echo "Failed to extract RDS identifier from Terraform state"
            RDS_INSTANCE_ID="N/A"
        else
            echo "Found RDS Identifier: $RDS_INSTANCE_ID"
        fi
        
        # Extract the ALB name from Terraform state
        ALB_NAME=$(terraform state show 'module.ecs_cluster[0].aws_lb.this' | grep -E "^    name[ ]+=" | awk -F= '{print $2}' | tr -d ' "')
        if [ -z "$ALB_NAME" ]; then
            echo "Failed to extract ALB name from Terraform state"
            ALB_NAME="N/A"
        else
            echo "Found ALB Name: $ALB_NAME"
        fi
        
        # Extract the ARN from the Terraform state
        SECRET_ARN=$(terraform state show 'module.base.aws_secretsmanager_secret.litellm_master_salt' | grep "arn" | head -1 | awk -F'"' '{print $2}')
        
        # Check if we got the ARN
        if [ -z "$SECRET_ARN" ]; then
            echo "Failed to extract ARN from Terraform state"
            LITELLM_MASTER_KEY="N/A"
        else
            echo "Found Secret ARN: $SECRET_ARN"
            
            # Use the ARN to get just the master key
            LITELLM_MASTER_KEY=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text | jq -r '.LITELLM_MASTER_KEY')
            
            if [ -z "$LITELLM_MASTER_KEY" ]; then
                echo "Failed to extract LITELLM_MASTER_KEY from secret"
                LITELLM_MASTER_KEY="N/A"
            fi
        fi
        
        # Set the login username
        LOGIN_USERNAME="admin"
        
        # Export these as environment variables for CloudFormation
        # Use 'export' to ensure they're available to the post_build phase
        export CF_API_ENDPOINT="$API_ENDPOINT"
        export CF_LITELLM_DASHBOARD_UI="$LITELLM_DASHBOARD_UI"
        export CF_ECS_CLUSTER_NAME="$ECS_CLUSTER_NAME"
        export CF_RDS_INSTANCE_ID="$RDS_INSTANCE_ID"
        export CF_LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY"
        export CF_LOGIN_USERNAME="$LOGIN_USERNAME"
        export CF_ALB_NAME="$ALB_NAME"
        
        # Print the outputs for logging (mask the master key for security)
        echo "API Endpoint: $CF_API_ENDPOINT"
        echo "Litellm Dashboard UI: $CF_LITELLM_DASHBOARD_UI"
        echo "ECS Cluster Name: $CF_ECS_CLUSTER_NAME"
        echo "RDS Instance ID: $CF_RDS_INSTANCE_ID"
        echo "ALB Name: $CF_ALB_NAME"
        echo "LITELLM Master Key: [MASKED]"
        echo "Login Username: $CF_LOGIN_USERNAME"
        
        # Write the environment variables to a file that will be sourced in post_build
        # This ensures they're available even if the script exits
        cat > /tmp/cf_exports.sh << EOF
export CF_API_ENDPOINT="$CF_API_ENDPOINT"
export CF_LITELLM_DASHBOARD_UI="$CF_LITELLM_DASHBOARD_UI"
export CF_ECS_CLUSTER_NAME="$CF_ECS_CLUSTER_NAME"
export CF_RDS_INSTANCE_ID="$CF_RDS_INSTANCE_ID"
export CF_LITELLM_MASTER_KEY="$CF_LITELLM_MASTER_KEY"
export CF_LOGIN_USERNAME="$CF_LOGIN_USERNAME"
export CF_ALB_NAME="$CF_ALB_NAME"
EOF
        
        # Make the exports file executable
        chmod +x /tmp/cf_exports.sh
        
        # Note: We're not attempting to update CloudFormation stack outputs directly.
        # Outputs are properly passed back to CloudFormation through the custom resource
        # response mechanism in the post_build phase of the CodeBuild project.
        
        cd ..
    fi
    
    # Ensure environment variables are available to the parent process
    # This is critical for CodeBuild to access these variables in the post_build phase
    echo "Exporting environment variables to parent process"
    echo "CF_API_ENDPOINT=$CF_API_ENDPOINT"
    echo "CF_LITELLM_DASHBOARD_UI=$CF_LITELLM_DASHBOARD_UI"
    echo "CF_ECS_CLUSTER_NAME=$CF_ECS_CLUSTER_NAME"
    echo "CF_RDS_INSTANCE_ID=$CF_RDS_INSTANCE_ID"
    echo "CF_LOGIN_USERNAME=$CF_LOGIN_USERNAME"
    
    # Create a file in the workspace root that will be sourced by the buildspec post_build phase
    echo "Creating exports file at $(pwd)/../cf_exports.sh"
    cat > ../cf_exports.sh << EOF
export CF_API_ENDPOINT="$CF_API_ENDPOINT"
export CF_LITELLM_DASHBOARD_UI="$CF_LITELLM_DASHBOARD_UI"
export CF_ECS_CLUSTER_NAME="$CF_ECS_CLUSTER_NAME"
export CF_RDS_INSTANCE_ID="$CF_RDS_INSTANCE_ID"
export CF_LITELLM_MASTER_KEY="$CF_LITELLM_MASTER_KEY"
export CF_LOGIN_USERNAME="$CF_LOGIN_USERNAME"
export CF_ALB_NAME="$CF_ALB_NAME"
EOF
    
    # Verify the file was created and show its contents
    if [ -f ../cf_exports.sh ]; then
        echo "Exports file created successfully"
        echo "File contents:"
        cat ../cf_exports.sh
        echo "File permissions:"
        ls -la ../cf_exports.sh
    else
        echo "ERROR: Failed to create exports file"
    fi
    
    # Show the absolute path for clarity
    echo "Absolute path to exports file: $(realpath ../cf_exports.sh)"
    
    echo "Deployment completed successfully"
}

# Function to undeploy the GenAI Gateway
undeploy_genai_gateway() {
    echo "Undeploying GenAI Gateway..."
    
    # Update Dockerfiles to use ECR Public Gallery for Python images
    update_dockerfiles
    
    # Run the deploy script first to initialize Terraform with the remote state
    echo "Initializing Terraform with remote state..."
    chmod +x deploy.sh
    
    # Use --skip-build flag to initialize Terraform without rebuilding everything
    echo "Running deploy.sh with --skip-build to initialize Terraform..."
    ./deploy.sh --skip-build
    
    if [ $? -ne 0 ]; then
        echo "Warning: Initialization with deploy.sh --skip-build had errors, but continuing with undeploy"
    else
        echo "Successfully initialized Terraform with remote state"
    fi
    
    # Now run the undeploy script
    echo "Running undeploy script..."
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
    setup_environment_create
    deploy_genai_gateway
    
    # Return to the original directory
    cd "$CURRENT_DIR"
    
elif [ "$STACK_OPERATION_LOWER" == "delete" ]; then
    clone_repository
    setup_environment_delete
    undeploy_genai_gateway
    
    # Return to the original directory
    cd "$CURRENT_DIR"
    
else
    echo "Invalid stack operation: $STACK_OPERATION"
    echo "Valid operations are: create, update, delete (case insensitive)"
    exit 1
fi

echo "Operation $STACK_OPERATION completed"
