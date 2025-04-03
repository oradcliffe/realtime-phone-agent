# Call Automation Deployment Guide

This guide will walk you through deploying the Call Automation app to Azure App Service with Key Vault integration and Azure AI Search capabilities.

## Files Overview

Here are all the files needed for deployment:

1. **Core Application Files**:
   - `call_automation.py` - Main application with Key Vault integration
   - `search_plugin.py` - Plugin for Azure AI Search integration

2. **Deployment Configuration**:
   - `requirements.txt` - Python dependencies
   - `startup.txt` - App startup command
   - `web.config` - IIS configuration with WebSocket support
   - `deploy.sh` - Deployment script for Azure resources

3. **Local Configuration**:
   - `.env` - Local environment variables (used to populate Key Vault)

## Prerequisites

Before deploying, ensure you have the following:

1. **Azure Resources**:
   - Azure subscription with access to create resources
   - Azure Communication Services instance with a phone number for inbound calls
   - Azure OpenAI service with a realtime-compatible model deployment
   - Azure AI Search service with an index for your product catalog
   - Azure Storage account (optional, if you want to store product data in blobs)

2. **Azure Resource Configuration**:
   - Communication Services: A phone number purchased and configured for inbound calls
   NOTE: although trial phone numbers are available in free subscriptions, they will not work properly. You must have a paid phone number.
   - OpenAI Service: A deployment of a model that supports realtime API (e.g., gpt-4o-realtime-preview)
   - AI Search: An index named "products" (or your preferred name) with fields:
     - name (String, Retrievable, Searchable)
     - description (String, Retrievable, Searchable)
     - price (Double, Retrievable, Filterable)
     - features (Collection(String), Retrievable, Searchable)
   - If using semantic search: A semantic configuration named "default" or update the code accordingly

3. **Local Tools**:
   - Azure CLI installed and authenticated (`az login`)
   - Git (optional, for version control)
   - Bash shell (or similar for running the deployment script)

4. **Configuration**:
   - A `.env` file with the following variables:
     ```
     ACS_CONNECTION_STRING=your_acs_connection_string
     AZURE_OPENAI_ENDPOINT=your_azure_openai_endpoint
     AZURE_OPENAI_REALTIME_DEPLOYMENT_NAME=your_deployment_name
     AZURE_OPENAI_API_VERSION=your_api_version (e.g., 2025-03-01-preview)
     AZURE_OPENAI_API_KEY=your_api_key
     AZURE_SEARCH_ENDPOINT=your_search_endpoint
     AZURE_SEARCH_KEY=your_search_key
     AZURE_SEARCH_INDEX=your_search_index_name
     ```

5. **Product Data**:
   - A populated Azure AI Search index with your product catalog
   - Either import data directly to your search index, or
   - Use the Azure portal's Import data wizard to pull data from:
     - Azure Blob Storage (JSON/CSV files)
     - Azure SQL Database
     - Cosmos DB
     - Or other supported data sources

## Setting up Azure AI Search Index

For the application to work correctly, you need to set up an Azure AI Search index with the appropriate schema:

1. **Create an Azure AI Search resource** in the Azure portal if you don't already have one

2. **Create a new index** with the following fields:
   - **name** (Edm.String)
     - Retrievable: Yes
     - Searchable: Yes
     - Analyzer: Standard.Lucene (or language-specific analyzer if needed)
   
   - **description** (Edm.String)
     - Retrievable: Yes
     - Searchable: Yes
     - Analyzer: Standard.Lucene
   
   - **price** (Edm.Double)
     - Retrievable: Yes
     - Filterable: Yes
   
   - **features** (Collection(Edm.String))
     - Retrievable: Yes
     - Searchable: Yes

3. **Enable semantic search capability** on your index:
   - Go to the "Semantic Configurations" tab
   - Create a new configuration named "default"
   - Select the relevant fields for title, content, and keyword fields
     - Title: name
     - Content: description
     - Keyword: features

4. **Import product data** into your index using one of these methods:
   - **Using the portal**:
     - Go to "Import data" in your search service
     - Select source (Blob storage, SQL, etc.)
     - Map fields to your index structure
     - Run the import

   - **Using code**:
     ```python
     from azure.search.documents import SearchClient
     from azure.core.credentials import AzureKeyCredential
     
     search_client = SearchClient(
         endpoint="your-search-endpoint",
         index_name="products",
         credential=AzureKeyCredential("your-search-key")
     )
     
     products = [
         {
             "id": "camera1",
             "name": "Pro X Camera",
             "description": "Professional-grade digital camera with 50MP resolution",
             "price": 1299.99,
             "features": ["50MP resolution", "8K video", "Weather-sealed body"]
         },
         # Add more products...
     ]
     
     search_client.upload_documents(products)
     ```

   - **Using Postman or other REST tools** to directly call the Search API

5. **Verify your index is working** by testing a few queries in the Azure portal's Search explorer

## Deployment Steps

1. **Create a directory for deployment**:
   ```bash
   mkdir call-automation-deploy
   cd call-automation-deploy
   ```

2. **Copy all files to this directory**:
   - `call_automation.py`
   - `search_plugin.py`
   - `requirements.txt`
   - `startup.txt`
   - `web.config`
   - `deploy.sh`
   - `.env` (your environment variables)

3. **Make the deployment script executable**:
   ```bash
   chmod +x deploy.sh
   ```

4. **Run the deployment script**:
   ```bash
   ./deploy.sh
   ```

   This script will:
   - Create a resource group
   - Create a Key Vault and populate it with your secrets
   - Create an App Service plan
   - Create a web app
   - Enable managed identity and grant Key Vault access
   - Configure WebSockets
   - Deploy your code using ZIP deployment

## Post-Deployment Steps

After successfully deploying your application, you need to configure these additional components:

### 1. Configure Event Grid for Call Notification

1. Go to your **Azure Communication Services** resource in the Azure portal
2. Select **Events** from the left navigation menu
3. Click **+ Event Subscription**
4. Fill in the details:
   - **Name**: IncomingCallEvents (or your preferred name)
   - **Event Schema**: Event Grid Schema
   - **Topic Types**: Azure Communication Services
   - **Filter to Event Types**: Check "Incoming Call"
   - **Endpoint Type**: Webhook
   - **Endpoint**: https://your-app-name.azurewebsites.net/api/incomingCall
   - Click "Create"

5. **Verify the Event Grid subscription**:
   - Azure will send a validation event to your endpoint
   - Your application should respond correctly if it's running
   - Check the Event Grid subscription status to ensure it shows as "Active"

### 2. Test Your Deployment

1. **Make a test call** to your ACS phone number
2. **Monitor the logs** to see the interaction:
   ```bash
   az webapp log tail --name your-app-name --resource-group call-automation-demo-rg
   ```
3. Verify that:
   - The call is answered
   - WebSocket connection is established
   - Azure OpenAI realtime model responds
   - Azure AI Search results are returned when asking about products

### 3. Set Up Application Insights (Optional)

For better monitoring and diagnostics:

1. Create an Application Insights resource in Azure
2. Connect it to your App Service:
   ```bash
   az webapp config appsettings set --name your-app-name --resource-group call-automation-demo-rg --settings APPLICATIONINSIGHTS_CONNECTION_STRING="your-connection-string"
   ```
3. Restart your web app to apply the changes

## How It Works

### Key Vault Integration

The application uses Azure Key Vault to securely store sensitive information:

1. The web app has a managed identity that can access Key Vault
2. At startup, the application fetches secrets from Key Vault
3. Secrets are loaded as environment variables
4. The application code uses these variables as normal

### Azure AI Search Integration

The application uses Azure AI Search for intelligent product search:

1. The `search_plugin.py` creates a plugin for Semantic Kernel
2. It connects to your Azure AI Search index using credentials from Key Vault
3. When customers ask about products, the AI model calls this plugin
4. The plugin passes the query to Azure AI Search and formats the results

### WebSocket Audio Streaming

The application uses WebSockets for real-time audio:

1. App Service is configured to support WebSockets
2. The application creates a WebSocket endpoint at `/ws`
3. Azure Communication Services connects to this endpoint
4. Audio is streamed bidirectionally between the caller and the AI model

## Troubleshooting

If you encounter issues:

1. **Check App Service logs**:
   ```bash
   az webapp log tail --name your-app-name --resource-group call-automation-demo-rg
   ```

2. **Verify Key Vault access**:
   ```bash
   az webapp identity show --name your-app-name --resource-group call-automation-demo-rg
   az keyvault show --name your-keyvault-name --resource-group call-automation-demo-rg
   ```

3. **Test the application endpoints manually**:
   - Try accessing `https://your-app-name.azurewebsites.net/` to see if the app is running
   - Use a WebSocket client to test the `/ws` endpoint

4. **Check for WebSocket issues**:
   - Ensure WebSockets are enabled in the App Service configuration
   - Verify the correct WebSocket URL is being used

5. **Check Azure AI Search connection**:
   - Verify the search index exists and is correctly configured
   - Check that the managed identity has access to Azure AI Search

## Security Considerations

- All secrets are stored in Key Vault
- The application uses managed identity for secure access
- No secrets are stored in code or app settings
- Consider adding additional logging for production use

## Scaling Considerations

For higher call volumes:

1. Scale up the App Service plan to a higher tier
2. Consider enabling auto-scaling
3. Monitor CPU/memory usage during calls
4. Optimize the search plugin for performance if needed