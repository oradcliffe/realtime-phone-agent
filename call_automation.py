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

# region: Semantic Kernel
kernel = Kernel()

class HelperPlugin:
    """Helper plugin for the Semantic Kernel."""

    @kernel_function
    def get_weather(self, location: str) -> str:
        """Get the weather for a location."""
        app.logger.info(f"@ Getting weather for {location}")
        weather_conditions = ("sunny", "hot", "cloudy", "raining", "freezing", "snowing")
        weather = weather_conditions[randint(0, len(weather_conditions) - 1)]  # nosec
        return f"The weather in {location} is {weather}."

    @kernel_function
    def get_date_time(self) -> str:
        """Get the current date and time."""
        app.logger.info("@ Getting current datetime")
        return f"The current date and time is {datetime.now().isoformat()}."

    @kernel_function
    async def goodbye(self):
        """When the user is done, say goodbye and then call this function."""
        app.logger.info("@ Goodbye has been called!")
        global call_connection_id
        await acs_client.get_call_connection(call_connection_id).hang_up(is_for_everyone=True)


kernel.add_plugin(plugin=HelperPlugin(), plugin_name="helpers", description="Helper functions for the realtime client.")

# Add the search plugin for product information
search_plugin = SearchPlugin()
kernel.add_plugin(plugin=search_plugin, plugin_name="search", description="Search for products in our catalog")

# region: Handlers for audio and data streams
async def from_realtime_to_acs(audio: ndarray):
    """Function that forwards the audio from the model to the websocket of the ACS client."""
    await websocket.send(
        json.dumps({"kind": "AudioData", "audioData": {"data": base64.b64encode(audio.tobytes()).decode("utf-8")}})
    )


async def from_acs_to_realtime(client: RealtimeClientBase):
    """Function that forwards the audio from the ACS client to the model."""
    while True:
        try:
            # Receive data from the ACS client
            stream_data = await websocket.receive()
            data = json.loads(stream_data)
            if data["kind"] == "AudioData":
                # send it to the Realtime service
                await client.send(
                    event=RealtimeAudioEvent(
                        audio=AudioContent(data=data["audioData"]["data"], data_format="base64", inner_content=data),
                    )
                )
        except Exception as e:
            app.logger.info(f"Websocket connection closed: {str(e)}")
            break


async def handle_realtime_messages(client: RealtimeClientBase):
    """Function that handles the messages from the Realtime service.

    This function only handles the non-audio messages.
    Audio is done through the callback so that it is faster and smoother.
    """
    async for event in client.receive(audio_output_callback=from_realtime_to_acs):
        match event.service_type:
            case ListenEvents.SESSION_CREATED:
                print("Session Created Message")
                print(f"  Session Id: {event.service_event.session.id}")
            case ListenEvents.ERROR:
                print(f"  Error: {event.service_event.error}")
            case ListenEvents.INPUT_AUDIO_BUFFER_CLEARED:
                print("Input Audio Buffer Cleared Message")
            case ListenEvents.INPUT_AUDIO_BUFFER_SPEECH_STARTED:
                print(f"Voice activity detection started at {event.service_event.audio_start_ms} [ms]")
                await websocket.send(json.dumps({"Kind": "StopAudio", "AudioData": None, "StopAudio": {}}))

            case ListenEvents.CONVERSATION_ITEM_INPUT_AUDIO_TRANSCRIPTION_COMPLETED:
                print(f" User:-- {event.service_event.transcript}")
            case ListenEvents.CONVERSATION_ITEM_INPUT_AUDIO_TRANSCRIPTION_FAILED:
                print(f"  Error: {event.service_event.error}")
            case ListenEvents.RESPONSE_DONE:
                print("Response Done Message")
                print(f"  Response Id: {event.service_event.response.id}")
                if event.service_event.response.status_details:
                    print(f"  Status Details: {event.service_event.response.status_details.model_dump_json()}")
            case ListenEvents.RESPONSE_AUDIO_TRANSCRIPT_DONE:
                print(f" AI:-- {event.service_event.transcript}")


# region: Routes

# WebSocket.
@app.websocket("/ws")
async def ws():
    app.logger.info("Client connected to WebSocket")

    # create the client, using the audio callback
    client = AzureRealtimeWebsocket()
    settings = AzureRealtimeExecutionSettings(
        instructions="""You are a helpful customer service agent for an outdoors equipment company. 
        Your name is Tammy and you help customers with product information and general inquiries.
        
        When customers ask about products, use the search.search_products function to look up 
        information in our product catalog. For example, if they ask about tents, call 
        search_products with "tents" as the query. For specific features, include those in 
        your search like "waterproof" or "breatheable".
        
        Always search for products before saying you don't have information. Only recommend 
        products that match what the customer is looking for.
        
        You are friendly but keep responses to the point and relevant.""",
        turn_detection={"type": "server_vad"},
        voice="shimmer",
        input_audio_format="pcm16",
        output_audio_format="pcm16",
        input_audio_transcription={"model": "whisper-1"},
        function_choice_behavior=FunctionChoiceBehavior.Auto(),
    )

    # create the realtime client session
    async with client(settings=settings, create_response=True, kernel=kernel):
        # start handling the messages from the realtime client
        # and allow the callback to be used to forward the audio to the acs client
        receive_task = asyncio.create_task(handle_realtime_messages(client))
        # receive messages from the ACS client and send them to the realtime client
        await from_acs_to_realtime(client)
        receive_task.cancel()


@app.route("/api/incomingCall", methods=["POST"])
async def incoming_call_handler() -> Response:
    app.logger.info("incoming event data")
    for event_dict in await request.json:
        event = EventGridEvent.from_dict(event_dict)
        app.logger.info("incoming event data --> %s", event.data)

        if event.event_type == SystemEventNames.EventGridSubscriptionValidationEventName:
            app.logger.info("Validating subscription")
            validation_code = event.data["validationCode"]
            validation_response = {"validationResponse": validation_code}
            return Response(response=json.dumps(validation_response), status=200)

        if event.event_type == "Microsoft.Communication.IncomingCall":
            app.logger.info("Incoming call received: data=%s", event.data)
            caller_id = (
                event.data["from"]["phoneNumber"]["value"]
                if event.data["from"]["kind"] == "phoneNumber"
                else event.data["from"]["rawId"]
            )
            app.logger.info("incoming call handler caller id: %s", caller_id)
            incoming_call_context = event.data["incomingCallContext"]
            guid = uuid.uuid4()
            query_parameters = urlencode({"callerId": caller_id})
            callback_uri = f"{CALLBACK_EVENTS_URI}/{guid}?{query_parameters}"

            parsed_url = urlparse(CALLBACK_EVENTS_URI)
            websocket_url = urlunparse(("wss", parsed_url.netloc, "/ws", "", "", ""))
            app.logger.info("callback url: %s", callback_uri)
            app.logger.info("websocket url: %s", websocket_url)

            media_streaming_options = MediaStreamingOptions(
                transport_url=websocket_url,
                transport_type=MediaStreamingTransportType.WEBSOCKET,
                content_type=MediaStreamingContentType.AUDIO,
                audio_channel_type=MediaStreamingAudioChannelType.MIXED,
                start_media_streaming=True,
                enable_bidirectional=True,
                audio_format=AudioFormat.PCM24_K_MONO,
            )
            answer_call_result = await acs_client.answer_call(
                incoming_call_context=incoming_call_context,
                operation_context="incomingCall",
                callback_url=callback_uri,
                media_streaming=media_streaming_options,
            )
            app.logger.info("Answered call for connection id: %s", answer_call_result.call_connection_id)
        return Response(status=200)
    return Response(status=200)


@app.route("/api/callbacks/<contextId>", methods=["POST"])
async def callbacks(contextId):
    for event in await request.json:
        # Parsing callback events
        global call_connection_id
        event_data = event["data"]
        call_connection_id = event_data["callConnectionId"]
        app.logger.info(
            f"Received Event:-> {event['type']}, Correlation Id:-> {event_data['correlationId']}, CallConnectionId:-> {call_connection_id}"  # noqa: E501
        )
        match event["type"]:
            case "Microsoft.Communication.CallConnected":
                call_connection_properties = await acs_client.get_call_connection(
                    call_connection_id
                ).get_call_properties()
                media_streaming_subscription = call_connection_properties.media_streaming_subscription
                app.logger.info(f"MediaStreamingSubscription:--> {media_streaming_subscription}")
                app.logger.info(f"Received CallConnected event for connection id: {call_connection_id}")
                app.logger.info("CORRELATION ID:--> %s", event_data["correlationId"])
                app.logger.info("CALL CONNECTION ID:--> %s", event_data["callConnectionId"])
            case "Microsoft.Communication.MediaStreamingStarted" | "Microsoft.Communication.MediaStreamingStopped":
                app.logger.info(f"Media streaming content type:--> {event_data['mediaStreamingUpdate']['contentType']}")
                app.logger.info(
                    f"Media streaming status:--> {event_data['mediaStreamingUpdate']['mediaStreamingStatus']}"
                )
                app.logger.info(
                    f"Media streaming status details:--> {event_data['mediaStreamingUpdate']['mediaStreamingStatusDetails']}"  # noqa: E501
                )
            case "Microsoft.Communication.MediaStreamingFailed":
                app.logger.info(
                    f"Code:->{event_data['resultInformation']['code']}, Subcode:-> {event_data['resultInformation']['subCode']}"  # noqa: E501
                )
                app.logger.info(f"Message:->{event_data['resultInformation']['message']}")
            case "Microsoft.Communication.CallDisconnected":
                pass
    return Response(status=200)


@app.route("/")
def home():
    return "Hello SKxACS CallAutomation!"


# region: Main
if __name__ == "__main__":
    app.logger.setLevel(INFO)