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

# Ask for deployment suffix
read -p "Enter a deployment suffix (leave blank for timestamp-based suffix): " DEPLOYMENT_SUFFIX

if [ -z "$DEPLOYMENT_SUFFIX" ]; then
  # Generate timestamp-based suffix
  DEPLOYMENT_SUFFIX=$(date +"%m%d%H%M")
  echo "Using timestamp-based suffix: $DEPLOYMENT_SUFFIX"
fi

# Variables
APP_SERVICE_PLAN="call-automation-plan"
APP_NAME="call-automation-app-$DEPLOYMENT_SUFFIX"
RUNTIME="PYTHON:3.10"
KEYVAULT_NAME="callkv$DEPLOYMENT_SUFFIX"

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

# Function to properly parse environment variables and add to Key Vault
add_secret_to_keyvault() {
  local line="$1"
  local keyvault_name="$2"
  
  # Skip empty lines and comments
  if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
    return 0
  fi
  
  # Extract key (part before first = sign)
  local key=$(echo "$line" | cut -d '=' -f1 | xargs)
  
  # Skip if key is empty
  if [[ -z "$key" ]]; then
    echo "Skipping line with empty key"
    return 0
  fi
  
  # Extract value using sed to preserve quotes
  local raw_value=$(echo "$line" | sed -e "s/^$key=//" -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  
  # Remove surrounding quotes if present (both ' and ")
  local value=$(echo "$raw_value" | sed -e 's/^["'\'']//' -e 's/["'\'']$//')
  
  # Convert environment variable name to Key Vault secret name
  local secret_name=$(echo "$key" | tr '_' '-')
  
  echo "Adding secret: $secret_name"
  
  # Set the secret in Key Vault with proper error handling
  if ! az keyvault secret set --vault-name "$keyvault_name" --name "$secret_name" --value "$value"; then
    echo "Failed to set secret $secret_name. Retrying in 30 seconds..."
    sleep 30
    echo "Retrying secret creation..."
    if ! az keyvault secret set --vault-name "$keyvault_name" --name "$secret_name" --value "$value"; then
      echo "ERROR: Failed to create secret $secret_name after retry. Check Key Vault logs."
      return 1
    fi
  fi
  
  # Add a 15-second delay between secret creations to avoid rate limiting
  echo "Waiting 15 seconds before adding the next secret..."
  sleep 15
  
  return 0
}

# Add secrets from .env file to Key Vault
echo "Adding secrets to Key Vault..."
if [ -f .env ]; then
  # Process each line in .env
  while IFS= read -r line || [ -n "$line" ]; do
    add_secret_to_keyvault "$line" "$KEYVAULT_NAME"
    if [ $? -ne 0 ]; then
      echo "WARNING: Failed to add some secrets to Key Vault."
    fi
  done < .env
else
  echo ".env file not found. Please create it first."
  exit 1
fi

# Create an App Service plan
echo "Creating App Service plan in $LOCATION..."
if [ -n "$tags" ]; then
  az appservice plan create --name $APP_SERVICE_PLAN --resource-group $RESOURCE_GROUP --location $LOCATION --sku B1 --is-linux --tags $tags
else
  az appservice plan create --name $APP_SERVICE_PLAN --resource-group $RESOURCE_GROUP --location $LOCATION --sku B1 --is-linux
fi

# Create a web app
echo "Creating web app..."
if [ -n "$tags" ]; then
  az webapp create --name $APP_NAME --resource-group $RESOURCE_GROUP --plan $APP_SERVICE_PLAN --runtime $RUNTIME --tags $tags
else
  az webapp create --name $APP_NAME --resource-group $RESOURCE_GROUP --plan $APP_SERVICE_PLAN --runtime $RUNTIME
fi

# Configure the web app to skip automated Oryx build
echo "Configuring web app settings..."
az webapp config appsettings set --name $APP_NAME --resource-group $RESOURCE_GROUP --settings \
  SCM_DO_BUILD_DURING_DEPLOYMENT=false

# Create Application Insights resource
echo "Creating Application Insights resource..."
APPINSIGHTS_NAME="call-automation-insights-$DEPLOYMENT_SUFFIX"

if [ -n "$tags" ]; then
  az monitor app-insights component create --app $APPINSIGHTS_NAME --location $LOCATION --resource-group $RESOURCE_GROUP --application-type web --tags $tags
else
  az monitor app-insights component create --app $APPINSIGHTS_NAME --location $LOCATION --resource-group $RESOURCE_GROUP --application-type web
fi

# Get the instrumentation key and connection string
APPINSIGHTS_KEY=$(az monitor app-insights component show --app $APPINSIGHTS_NAME --resource-group $RESOURCE_GROUP --query instrumentationKey -o tsv)
APPINSIGHTS_CONNECTION_STRING=$(az monitor app-insights component show --app $APPINSIGHTS_NAME --resource-group $RESOURCE_GROUP --query connectionString -o tsv)

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
  "CALLBACK_URI_HOST=https://$APP_NAME.azurewebsites.net" \
  "APPINSIGHTS_INSTRUMENTATIONKEY=$APPINSIGHTS_KEY" \
  "APPLICATIONINSIGHTS_CONNECTION_STRING=$APPINSIGHTS_CONNECTION_STRING" \
  "ApplicationInsightsAgent_EXTENSION_VERSION=~3"

# Set WebSocket enabling configuration
echo "Enabling WebSockets..."
az webapp config set --name $APP_NAME --resource-group $RESOURCE_GROUP --web-sockets-enabled true

# Set the startup command to use our custom startup script
echo "Setting startup command..."
az webapp config set --name $APP_NAME --resource-group $RESOURCE_GROUP --startup-file "/home/site/wwwroot/startup.sh"

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

# Deploy the application
echo "Deploying the application..."
# Use improved deployment method
az webapp deployment source config-zip \
  --resource-group $RESOURCE_GROUP \
  --name $APP_NAME \
  --src "temp_deploy/app.zip"

# Verify deployment status
echo "Verifying deployment status..."
MAX_ATTEMPTS=10
ATTEMPT=0
DELAY=30

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  ATTEMPT=$((ATTEMPT+1))
  STATUS=$(az webapp deployment list --name $APP_NAME --resource-group $RESOURCE_GROUP --query "[0].status" -o tsv 2>/dev/null)
  
  if [ "$STATUS" = "Success" ]; then
    echo "✓ Deployment completed successfully"
    break
  elif [ "$STATUS" = "Failed" ]; then
    echo "✗ Deployment failed. Check logs for details."
    echo "You can check logs with: az webapp log tail --name $APP_NAME --resource-group $RESOURCE_GROUP"
    exit 1
  else
    echo "Deployment status: $STATUS. Checking again in $DELAY seconds... (Attempt $ATTEMPT/$MAX_ATTEMPTS)"
    sleep $DELAY
  fi
  
  if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo "Warning: Deployment is taking longer than expected."
    read -p "Continue waiting for deployment? (y/n): " continue_waiting
    if [ "$continue_waiting" == "y" ] || [ "$continue_waiting" == "Y" ]; then
      MAX_ATTEMPTS=$((MAX_ATTEMPTS+5))
    else
      echo "Moving on, but deployment may not be complete."
      break
    fi
  fi
done

# Restart the web app to ensure all settings are applied
echo "Restarting the web app..."
az webapp restart --name $APP_NAME --resource-group $RESOURCE_GROUP

echo "Cleaning up temporary files..."
rm -rf temp_deploy

# Display the application URL
echo "Deployment completed. Your application is available at:"
echo "https://$APP_NAME.azurewebsites.net"

# Display Key Vault info
echo "Azure Key Vault created: $KEYVAULT_NAME"
echo "Key Vault URL: https://$KEYVAULT_NAME.vault.azure.net/"

# Display Application Insights info
echo "Application Insights created: $APPINSIGHTS_NAME"
echo "To view insights, visit: https://portal.azure.com/#resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/microsoft.insights/components/$APPINSIGHTS_NAME/overview"

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