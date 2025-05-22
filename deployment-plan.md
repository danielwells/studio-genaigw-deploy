# GenAI Gateway Workshop Deployment Plan

## 1. Script Structure
- Create a single bash script named `manage-workshop-stack.sh` at the root level of the repository
- The script will handle different operations (create, update, delete) based on the `$STACK_OPERATION` parameter
- Include proper error handling and logging

## 2. Prerequisites Check
Before proceeding with any operations, verify that the following tools are installed:
1. Docker CLI - Required for building Docker images
2. AWS CLI - Required for AWS resource management
3. Terraform CLI - Required for infrastructure deployment
4. yq utility **specifically version v4.40.5** - Required for YAML processing

## 3. Create/Update Operation Steps
1. Check prerequisites
2. Clone the GenAI Gateway repository: `git clone https://github.com/aws-samples/genai-gateway.git`
3. Copy the template environment file: `cp .env.template .env`
4. Generate a globally unique S3 bucket name for Terraform state
5. Update the `.env` file to set `TERRAFORM_S3_BUCKET_NAME` to this unique bucket name
6. Create the S3 bucket for Terraform state if it doesn't exist
7. Run the `deploy.sh` script from the root of the cloned repository, which will:
   - Execute Terraform scripts to provision infrastructure
   - Build and deploy Docker containers
   - Configure any additional resources needed

## 4. Delete Operation Steps
1. Check prerequisites
2. If the repository is not already cloned, clone it
3. Run the `undeploy.sh` script from the root of the cloned repository, which will:
   - Destroy resources created by Terraform
   - Remove Docker containers and images
   - Clean up any other created resources
4. Empty and delete the Terraform state S3 bucket

## 5. Environment Variables to Utilize
- `PARTICIPANT_ROLE_ARN` and `PARTICIPANT_ASSUMED_ROLE_ARN` - For permissions
- `ASSETS_BUCKET_NAME` and `ASSETS_BUCKET_PREFIX` - For accessing workshop assets
- `IS_WORKSHOP_STUDIO_ENV` - To determine if running in Workshop Studio

## 6. Testing Strategy
- Test locally by setting environment variables manually
- Verify the script can check for prerequisites correctly
- Verify the script can clone the repository and set up the environment
- Verify the create operation runs deploy.sh successfully and Terraform scripts execute properly
- Verify the delete operation runs undeploy.sh successfully and cleans up all resources

## 7. Repository Structure
- `/manage-workshop-stack.sh` - Main deployment script
- `/static/WorkshopStack.yaml` - Workshop Studio CloudFormation template
- Update `contentspec.yaml` with infrastructure section
