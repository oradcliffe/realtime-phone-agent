# Call Automation Demo with Azure AI Search

This project demonstrates how to build an AI-powered customer service agent using Azure Communication Services, Azure OpenAI with realtime capabilities, Semantic Kernel, and Azure AI Search for product information retrieval.  See [rag-flow.mmd](rag-flow.mmd) for call flow with services involved.

## Features

- Automated phone call answering with natural conversation
- AI-powered agent using Azure OpenAI's realtime capabilities
- Intelligent product search using Azure AI Search
- Secure secrets management with Azure Key Vault
- WebSocket-based audio streaming

## Prerequisites

Before deploying this application, make sure you have:

- An Azure subscription with access to:
  - Azure Communication Services
  - Azure OpenAI Service
  - Azure AI Search
  - Azure Key Vault
  - Azure App Service
- A properly configured search index with product data
- A phone number in Azure Communication Services

## Important Security Note

**Never upload your `.env` file to GitHub or any public repository!** This file contains sensitive credentials and API keys.

Instead:
1. Create a `.env` file locally based on the template in the deployment guide
2. Fill in your own values for each environment variable
3. Keep this file secure and only on your local development machine

## Project Structure

- `call_automation.py` - Main application with realtime audio capabilities
- `search_plugin.py` - Semantic Kernel plugin for Azure AI Search
- `requirements.txt` - Python dependencies
- `startup.txt` - App startup command for Azure App Service
- `web.config` - IIS configuration for WebSocket support
- `deploy.sh` - Deployment script for creating Azure resources
- `.gitignore` - Prevents sensitive files from being uploaded
- `deployment-guide.md` - Detailed deployment instructions

## Deployment

Follow the step-by-step instructions in the [deployment guide](deployment-guide.md) to set up and deploy the application.

## Local Development

To run the application locally (have not tested this):

1. Create a `.env` file with your Azure credentials (see deployment guide)
2. Install dependencies: `pip install -r requirements.txt`
3. Run with: `hypercorn call_automation:app --bind 0.0.0.0:8080`

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgements

This project is based on code from the [Microsoft Semantic Kernel repository](https://github.com/microsoft/semantic-kernel), specifically the call automation demo in the Python samples. The original code is copyright Microsoft Corporation and is used under the MIT License.

The project uses:
- Azure Communication Services for telephony
- Azure OpenAI Service for conversation capabilities 
- Azure AI Search for product information retrieval
- Azure Key Vault for secure secrets management

Code files borrowed from the original repository maintain their original copyright notices and MIT license.