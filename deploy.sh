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
  LOCATION=$(az group show --name "$RESOURCE_GROUP" --query "location" -o tsv)
  echo "Using location: $LOCATION"
else
  LOCATION="eastus2"
fi

# Variables
APP_SERVICE_PLAN="call-automation-plan"
APP_NAME="call-automation-app-$RANDOM"
RUNTIME="PYTHON:3.10"
KEYVAULT_NAME="callautomation-kv-$RANDOM"

# Create a Key Vault
echo "Creating Azure Key Vault..."
az keyvault create --name $KEYVAULT_NAME --resource-group $RESOURCE_GROUP --location $LOCATION

# Elevate permissions for the current user
echo "Granting the current user permissions to manage secrets..."
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
az keyvault set-policy --name $KEYVAULT_NAME --resource-group $RESOURCE_GROUP --object-id $USER_OBJECT_ID --secret-permissions get list set delete backup restore recover purge

# Add secrets from .env file to Key Vault
echo "Adding secrets to Key Vault..."
if [ -f .env ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    # Skip empty lines and comments
    if [[ -z "$key" || "$key" =~ ^# ]]; then
      continue
    fi
    
    # Remove surrounding quotes if present
    value=$(echo $value | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    
    # Convert environment variable names to Key Vault secret names (replace _ with -)
    secret_name=$(echo $key | tr '_' '-')
    
    echo "Adding secret: $secret_name"
    az keyvault secret set --vault-name $KEYVAULT_NAME --name $secret_name --value "$value"
  done < .env
else
  echo ".env file not found. Please create it first."
  exit 1
fi

# Create an App Service plan
echo "Creating App Service plan..."
az appservice plan create --name $APP_SERVICE_PLAN --resource-group $RESOURCE_GROUP --sku B1 --is-linux

# Create a web app
echo "Creating web app..."
az webapp create --name $APP_NAME --resource-group $RESOURCE_GROUP --plan $APP_SERVICE_PLAN --runtime $RUNTIME

# Enable managed identity for the web app
echo "Enabling managed identity..."
az webapp identity assign --name $APP_NAME --resource-group $RESOURCE_GROUP

# Get the principal ID of the web app's managed identity
PRINCIPAL_ID=$(az webapp identity show --name $APP_NAME --resource-group $RESOURCE_GROUP --query principalId --output tsv)

# Grant the web app access to Key Vault
echo "Granting Key Vault access to web app..."
az keyvault set-policy --name $KEYVAULT_NAME --resource-group $RESOURCE_GROUP --object-id $PRINCIPAL_ID --secret-permissions get list

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

# Deploy the code - using ZIP deployment for reliability
echo "Deploying the application..."
zip -r deployment.zip .
az webapp deployment source config-zip --resource-group $RESOURCE_GROUP --name $APP_NAME --src deployment.zip

# Display the application URL
echo "Deployment completed. Your application is available at:"
echo "https://$APP_NAME.azurewebsites.net"

# Display Key Vault info
echo "Azure Key Vault created: $KEYVAULT_NAME"
echo "Key Vault URL: https://$KEYVAULT_NAME.vault.azure.net/"

# Remind about Azure AI Search permissions
echo "IMPORTANT: Don't forget to grant the App Service managed identity access to your Azure AI Search resource:"
echo "Run the following command (replace with your values):"
echo "az role assignment create --assignee $PRINCIPAL_ID --role \"Search Index Reader\" --scope /subscriptions/YOUR_SUBSCRIPTION_ID/resourceGroups/YOUR_SEARCH_RG/providers/Microsoft.Search/searchServices/YOUR_SEARCH_SERVICE"

# Remind to update Event Grid subscription
echo "IMPORTANT: Update your Event Grid subscription to point to:"
echo "https://$APP_NAME.azurewebsites.net/api/incomingCall"