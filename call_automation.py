# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# 
# Original source: https://github.com/microsoft/semantic-kernel/tree/main/python/samples/demos/call_automation
#
# This file has been modified from the original version.

import asyncio
import base64
import os
import uuid
from datetime import datetime
from logging import INFO
from random import randint
from urllib.parse import urlencode, urlparse, urlunparse

# Key Vault Integration
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

# Application Insights Integration
from opencensus.ext.azure.log_exporter import AzureLogHandler
import logging

# Azure Communication Services imports
from azure.communication.callautomation import (
    AudioFormat,
    MediaStreamingAudioChannelType,
    MediaStreamingContentType,
    MediaStreamingOptions,
    MediaStreamingTransportType,
)
from azure.communication.callautomation.aio import CallAutomationClient
from azure.eventgrid import EventGridEvent, SystemEventNames
from numpy import ndarray
from quart import Quart, Response, json, request, websocket

# Semantic Kernel imports
from semantic_kernel import Kernel
from semantic_kernel.connectors.ai import FunctionChoiceBehavior
from semantic_kernel.connectors.ai.open_ai import (
    AzureRealtimeExecutionSettings,
    AzureRealtimeWebsocket,
)
from semantic_kernel.connectors.ai.open_ai.services._open_ai_realtime import ListenEvents
from semantic_kernel.connectors.ai.realtime_client_base import RealtimeClientBase
from semantic_kernel.contents import AudioContent, RealtimeAudioEvent
from semantic_kernel.functions import kernel_function

# Import custom plugins
from search_plugin import SearchPlugin

# Setup Key Vault integration
def load_secrets_from_keyvault():
    """Load secrets from Azure Key Vault if configured"""
    keyvault_url = os.environ.get("AZURE_KEYVAULT_URL")
    
    if not keyvault_url:
        print("No Key Vault URL found, using environment variables directly")
        return
    
    try:
        print(f"Connecting to Key Vault: {keyvault_url}")
        credential = DefaultAzureCredential()
        client = SecretClient(vault_url=keyvault_url, credential=credential)
        
        # List of secrets to fetch from Key Vault
        secret_names = [
            "ACS-CONNECTION-STRING",
            "AZURE-OPENAI-ENDPOINT",
            "AZURE-OPENAI-REALTIME-DEPLOYMENT-NAME",
            "AZURE-OPENAI-API-VERSION",
            "AZURE-OPENAI-API-KEY",
            "AZURE-SEARCH-ENDPOINT",
            "AZURE-SEARCH-KEY",
            "AZURE-SEARCH-INDEX"
        ]
        
        # Fetch each secret and set as environment variable
        for secret_name in secret_names:
            try:
                # Key Vault secrets use hyphens instead of underscores
                env_name = secret_name.replace("-", "_")
                secret = client.get_secret(secret_name)
                os.environ[env_name] = secret.value
                print(f"Loaded secret: {env_name}")
            except Exception as e:
                print(f"Error loading secret {secret_name}: {str(e)}")
    
    except Exception as e:
        print(f"Error connecting to Key Vault: {str(e)}")

# Load secrets at startup
load_secrets_from_keyvault()

# Callback events URI to handle callback events.
CALLBACK_URI_HOST = os.environ.get("CALLBACK_URI_HOST", "https://your-app-name.azurewebsites.net")
CALLBACK_EVENTS_URI = CALLBACK_URI_HOST + "/api/callbacks"

acs_client = CallAutomationClient.from_connection_string(os.environ["ACS_CONNECTION_STRING"])
app = Quart(__name__)

# Initialize Application Insights if configured
if 'APPINSIGHTS_INSTRUMENTATIONKEY' in os.environ:
    app.logger.setLevel(logging.INFO)
    app.logger.addHandler(AzureLogHandler(
        connection_string=os.environ.get('APPLICATIONINSIGHTS_CONNECTION_STRING')
    ))
    app.logger.info("Application Insights initialized")

# Continue with the rest of the file...