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
   - `zip` command installed
     - This is required for creating the deployment package
     - Most Linux distributions and macOS have this installed by default
     - For Windows, use WSL or install via GnuWin32

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
   - A populated Azure AI Search index with your product catalog (sample data included in `products.json.example`)
   - Either import data directly to your search index, or
   - Use the Azure portal's Import data wizard to pull data from:
     - Azure Blob Storage (JSON/CSV files)
     - Azure SQL Database
     - Cosmos DB
     - Or other supported data sources

## Permission Model Overview

The application requires specific permissions between services. Here's a summary of required permissions and best practices:

### Required Permissions

1. **App Service → Key Vault**:
   - The App Service needs to read secrets from Key Vault
   - **Best practice**: Use Managed Identity with "Key Vault Secrets User" role

2. **App Service → Azure AI Search**:
   - The App Service needs to query the search index
   - **Best practice**: Use Managed Identity with "Search Index Reader" role

3. **Azure AI Search → Blob Storage** (for data ingestion):
   - Search needs to read data from Blob Storage for indexing
   - **Best practice**: Use Managed Identity with "Storage Blob Data Reader" role

### Implementation in this Solution

- The deployment script automatically sets up the App Service → Key Vault permissions
- You must manually configure the App Service → Azure AI Search permissions (see Post-Deployment Steps)
- If using blob storage for indexing, you'll need to configure Azure AI Search → Blob Storage permissions separately

Using Managed Identities throughout provides the best balance of security and ease of management without requiring credential rotation.

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

3. **Configure semantic search capabilities** for your index:
   - **Create a semantic configuration**:
     - Go to the "Semantic Configurations" tab in your index
     - Create a new configuration named "default" (this name matches what's used in the code)
     - Map your index fields to semantic roles:
       - Title field: `name`
       - Content field: `description`
       - Keyword fields: `features`
   
   - **Enable semantic ranker**:
     - Note: The semantic configuration above defines *how* your data should be understood semantically
     - The application code enables the semantic ranker at query time by using:
       ```python
       results = self.search_client.search(
           query,
           query_type="semantic",
           semantic_configuration_name="default"
       )
       ```
     - This combination of configuration and query-time settings enables the full semantic search capability

4. **Setting up the Azure AI Search Indexer**

   After creating your index and configuring semantic search, you'll need to set up an indexer to populate your index with product data:

   ### Creating an Indexer for JSON Array Data

   1. **Upload your JSON data file**:
      - Upload the `products.json.example` file to an Azure Blob Storage container
      - Make note of the storage account name, container name, and blob name

   2. **Create a data source**:
      - In your Azure AI Search service, go to "Data sources" → "Add data source"
      - Select "Azure Blob Storage" as the source
      - Connect to your storage account using a connection string or managed identity
      - Select the container where you uploaded the JSON file

   3. **Configure parsing mode**:
      - In the "Parser configuration" section, set:
        - **Parsing mode**: JSON array
        - **Document root**: Leave blank (to process the entire array)
        - This tells the indexer that your file contains a JSON array with multiple objects

   4. **Create the indexer**:
      - Give your indexer a name
      - Set an appropriate schedule (or run once for initial load)

   5. **Run the indexer**:
      - Once configured, run the indexer to populate your index
      - Monitor the indexer status to ensure all documents are successfully processed

   ### Indexer Permissions

   If using managed identity (recommended), ensure your Azure AI Search service has been granted at least "Storage Blob Data Reader" role on the blob storage account or container where your product data resides.

**Verify your index is working** by testing a few queries in the Azure portal's Search explorer

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

3. **Run the deployment script**:
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

### 1. Grant Azure AI Search Permissions

Your App Service needs permissions to access your Azure AI Search index:

```bash
# Get the principal ID of the App Service's managed identity
PRINCIPAL_ID=$(az webapp identity show --name your-app-name --resource-group call-automation-demo-rg --query principalId --output tsv)

# Grant Search Index Reader role on the Azure AI Search resource
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Search Index Reader" \
  --scope /subscriptions/your-subscription-id/resourceGroups/your-resource-group/providers/Microsoft.Search/searchServices/your-search-service-name
```

Alternatively, through the Azure Portal:
1. Go to your Azure AI Search resource
2. Select "Access control (IAM)" → "Add" → "Add role assignment"
3. Choose "Search Index Reader" role
4. Under "Assign access to," select "Managed identity"
5. Click "Select members" and choose your App Service's managed identity
6. Complete the assignment

### 2. Configure Event Grid for Call Notification

1. Go to your **Azure Communication Services** resource in the Azure portal
2. Select **Events** from the left navigation menu
3. Click **+ Event Subscription**
4. Fill in the details:
   - **Name**: IncomingCallEvents (or your preferred name)
   - **Event Schema**: Event Grid Schema
   - **Topic Types**: Azure Communication Services
   - **Filter to Event Types**: Check "Incoming Call" - Microsoft.Communication.IncomingCall
   - **Endpoint Type**: Webhook
   - **Endpoint**: https://your-app-name.azurewebsites.net/api/incomingCall
   - Click "Create"

5. **Verify the Event Grid subscription**:
   - Azure will send a validation event to your endpoint
   - Your application should respond correctly if it's running
   - Check the Event Grid subscription status to ensure it shows as "Active"

### 3. Test Your Deployment

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

### 4. Set Up Application Insights (Optional)

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