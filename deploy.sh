#!/bin/bash

# Check if user wants to use an existing resource group
read -p "Do you want to use an existing resource group? (y/n): " use_existing_rg

if [ "$use_existing_rg" == "y" ] || [ "$use_existing_rg" == "Y" ]; then
  # List available resource groups
  echo "Available resource groups:"
  az group list --query "[].name" -o tsv
  
  # Ask for the resource group name
  read -p "Enter the name of the existing resource group: " RESOURCE_GROUP
  
  # Verify resource group exists
  if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
    echo "Resource group '$RESOURCE_GROUP' doesn't exist. Please check the name and try again."
    exit 1
  fi
  
  echo "Using existing resource group: $RESOURCE_GROUP"
else
  # Variables for new resource group
  RESOURCE_GROUP="call-automation-demo-rg"
  LOCATION="eastus2"
  
  # Create a resource group
  echo "Creating resource group..."
  az group create --name $RESOURCE_GROUP --location $LOCATION
fi

# Get user's location for resources if needed
if [ "$use_existing_rg" == "y" ] || [ "$use_existing_rg" == "Y" ]; then
  # Get the location from the existing resource group
  RG_LOCATION=$(az group show --name "$RESOURCE_GROUP" --query "location" -o tsv)
  echo "The resource group is in location: $RG_LOCATION"
  
  # Ask if user wants to use the same location
  read -p "Do you want to use the same location for new resources? (y/n): " use_same_location
  
  if [ "$use_same_location" == "y" ] || [ "$use_same_location" == "Y" ]; then
    LOCATION=$RG_LOCATION
    echo "Using location: $LOCATION"
  else
    echo "Example locations: eastus, eastus2, westus2, centralus, northeurope, westeurope"
    read -p "Enter the location for new resources: " LOCATION
    echo "Using custom location: $LOCATION"
  fi
else
  echo "Example locations: eastus, eastus2, westus2, centralus, northeurope, westeurope"
  read -p "Enter the location for new resources (default is eastus2): " input_location
  LOCATION=${input_location:-eastus2}
  echo "Using location: $LOCATION"
fi

# Ask for tags
echo "Would you like to add tags to your resources? Tags help with resource organization and cost tracking."
read -p "Add tags to resources? (y/n): " add_tags

if [ "$add_tags" == "y" ] || [ "$add_tags" == "Y" ]; then
  # Initialize tags string
  tags=""
  
  # Collect default tags
  echo "Let's add some common tags:"
  
  # Environment tag
  read -p "Environment (e.g., dev, test, prod) [prod]: " env_tag
  env_tag=${env_tag:-prod}
  tags="Environment=$env_tag"
  
  # Project tag
  read -p "Project name [call-automation]: " project_tag
  project_tag=${project_tag:-call-automation}
  tags="$tags Project=$project_tag"
  
  # Owner tag
  read -p "Owner (e.g., team name or email) [ai-team]: " owner_tag
  owner_tag=${owner_tag:-ai-team}
  tags="$tags Owner=$owner_tag"
  
  # Ask for additional custom tags
  read -p "Would you like to add custom tags? (y/n): " add_custom_tags
  
  if [ "$add_custom_tags" == "y" ] || [ "$add_custom_tags" == "Y" ]; then
    custom_tags_done=false
    
    while [ "$custom_tags_done" == "false" ]; do
      read -p "Enter tag key: " tag_key
      read -p "Enter tag value: " tag_value
      
      # Add to existing tags
      tags="$tags $tag_key=$tag_value"
      
      read -p "Add another custom tag? (y/n): " add_another
      if [ "$add_another" != "y" ] && [ "$add_another" != "Y" ]; then
        custom_tags_done=true
      fi
    done
  fi
  
  echo "Using tags: $tags"
else
  tags=""
  echo "No tags will be applied."
fi

# Variables
APP_SERVICE_PLAN="call-automation-plan"
APP_NAME="call-automation-app-$RANDOM"
RUNTIME="PYTHON:3.10"
KEYVAULT_NAME="callautomation-kv-$RANDOM"

# Create a Key Vault with RBAC authorization
echo "Creating Azure Key Vault..."
if [ -n "$tags" ]; then
  az keyvault create --name $KEYVAULT_NAME --resource-group $RESOURCE_GROUP --location $LOCATION --enable-rbac-authorization true --tags $tags
else
  az keyvault create --name $KEYVAULT_NAME --resource-group $RESOURCE_GROUP --location $LOCATION --enable-rbac-authorization true
fi

# Get the current user's Object ID for RBAC assignment
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# Grant the current user Key Vault Secrets Officer role for managing secrets
echo "Granting the current user Key Vault Secrets Officer role..."
az role assignment create --assignee $USER_OBJECT_ID --role "Key Vault Secrets Officer" --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEYVAULT_NAME"

# Wait for RBAC role assignment to propagate (this is important!)
echo "Waiting 30 seconds for RBAC role assignment to propagate..."
sleep 30

# Add secrets from .env file to Key Vault
echo "Adding secrets to Key Vault..."
if [ -f .env ]; then
  # Read the file line by line, preserving quotes and special characters
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and comments
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    
    # Extract key (part before first = sign)
    key=$(echo "$line" | cut -d '=' -f1)
    
    # Extract value (everything after first = sign)
    value="${line#*=}"
    
    # Trim whitespace from key
    key=$(echo "$key" | xargs)
    
    # Handle value carefully to preserve all characters
    # Remove only the very first and last quote if they're both present
    if [[ "$value" == "'"*"'" ]] || [[ "$value" == "\""*"\"" ]]; then
      value="${value:1:${#value}-2}"
    fi
    
    # Convert environment variable names to Key Vault secret names (replace _ with -)
    secret_name=$(echo "$key" | tr '_' '-')
    
    echo "Adding secret: $secret_name"
    # Try to set the secret with full value, and if it fails, provide more detailed error
    if ! az keyvault secret set --vault-name $KEYVAULT_NAME --name "$secret_name" --value "$value"; then
      echo "Failed to set secret $secret_name. Retrying in 30 seconds..."
      sleep 30
      echo "Retrying secret creation..."
      az keyvault secret set --vault-name $KEYVAULT_NAME --name "$secret_name" --value "$value"
    fi
    
    # Add a 10-second delay between secret creations to avoid rate limiting
    echo "Waiting 10 seconds before adding the next secret..."
    sleep 10
  done < .env
else
  echo ".env file not found. Please create it first."
  exit 1
fi

# Create an App Service plan
echo "Creating App Service plan..."
if [ -n "$tags" ]; then
  az appservice plan create --name $APP_SERVICE_PLAN --resource-group $RESOURCE_GROUP --sku B1 --is-linux --tags $tags
else
  az appservice plan create --name $APP_SERVICE_PLAN --resource-group $RESOURCE_GROUP --sku B1 --is-linux
fi

# Create a web app
echo "Creating web app..."
if [ -n "$tags" ]; then
  az webapp create --name $APP_NAME --resource-group $RESOURCE_GROUP --plan $APP_SERVICE_PLAN --runtime $RUNTIME --tags $tags
else
  az webapp create --name $APP_NAME --resource-group $RESOURCE_GROUP --plan $APP_SERVICE_PLAN --runtime $RUNTIME
fi

# Enable managed identity for the web app
echo "Enabling managed identity..."
az webapp identity assign --name $APP_NAME --resource-group $RESOURCE_GROUP

# Get the principal ID of the web app's managed identity
PRINCIPAL_ID=$(az webapp identity show --name $APP_NAME --resource-group $RESOURCE_GROUP --query principalId --output tsv)

# Grant Key Vault Secrets User role to the web app's managed identity
echo "Granting Key Vault Secrets User role to the web app's managed identity..."
az role assignment create --assignee $PRINCIPAL_ID --role "Key Vault Secrets User" --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEYVAULT_NAME"

# Set Key Vault reference app settings
echo "Setting Key Vault reference app settings..."
az webapp config appsettings set --name $APP_NAME --resource-group $RESOURCE_GROUP --settings \
  "AZURE_KEYVAULT_URL=https://$KEYVAULT_NAME.vault.azure.net/"

# Create a special setting for the callback URL (which isn't a secret but needs to be the app's URL)
az webapp config appsettings set --name $APP_NAME --resource-group $RESOURCE_GROUP --settings \
  "CALLBACK_URI_HOST=https://$APP_NAME.azurewebsites.net"

# Set WebSocket enabling configuration
echo "Enabling WebSockets..."
az webapp config set --name $APP_NAME --resource-group $RESOURCE_GROUP --web-sockets-enabled true

# Set startup command
echo "Setting startup command..."
az webapp config set --name $APP_NAME --resource-group $RESOURCE_GROUP --startup-file "startup.txt"

# Create temp directory for zip
echo "Preparing application for deployment..."
mkdir -p temp_deploy

# Create a list of files to exclude from deployment
echo "Creating deployment package..."
cat > temp_deploy/exclude.txt << EOL
.env*
.git/
.gitignore
deploy.sh
deployment-guide.md
LICENSE
products.json.example
README.md
temp_deploy/
EOL

# Create a zip file in the temp directory, excluding unnecessary files
echo "Creating deployment package..."
# Check if zip command is available
if command -v zip &> /dev/null; then
  # Create a zip of the current directory contents, excluding specified files
  zip -r temp_deploy/app.zip . -x@temp_deploy/exclude.txt
else
  echo "zip command not found. Please install zip or use an environment where zip is available."
  exit 1
fi

# Deploy the application using the newer az webapp deploy command
echo "Deploying the application..."
# Use specific target path to avoid subfolder issues
az webapp deploy \
  --resource-group $RESOURCE_GROUP \
  --name $APP_NAME \
  --src-path "temp_deploy/app.zip" \
  --type zip \
  --target-path "/home/site/wwwroot" \
  --timeout 300 \
  --async true

# Add a small wait to allow async deployment to start
echo "Waiting for deployment to start..."
sleep 10

echo "Cleaning up temporary files..."
rm -rf temp_deploy

# Display the application URL
echo "Deployment completed. Your application is available at:"
echo "https://$APP_NAME.azurewebsites.net"

# Display Key Vault info
echo "Azure Key Vault created: $KEYVAULT_NAME"
echo "Key Vault URL: https://$KEYVAULT_NAME.vault.azure.net/"

# Applied tags summary
if [ -n "$tags" ]; then
  echo "Applied tags to resources: $tags"
fi

# Remind about Azure AI Search permissions
echo "IMPORTANT: Don't forget to grant the App Service managed identity access to your Azure AI Search resource:"
echo "Run the following command (replace with your values):"
echo "az role assignment create --assignee $PRINCIPAL_ID --role \"Search Index Reader\" --scope /subscriptions/YOUR_SUBSCRIPTION_ID/resourceGroups/YOUR_SEARCH_RG/providers/Microsoft.Search/searchServices/YOUR_SEARCH_SERVICE"

# Remind to update Event Grid subscription
echo "IMPORTANT: Update your Event Grid subscription to point to:"
echo "https://$APP_NAME.azurewebsites.net/api/incomingCall"