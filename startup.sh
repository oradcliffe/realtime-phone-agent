#!/bin/bash

# Install required packages
echo "Installing Python packages..."
pip install -r requirements.txt

# Start the application using hypercorn with dynamic port
echo "Starting application..."
PORT=${PORT:-8000}  # Use PORT env variable if set, otherwise default to 8000
python -m hypercorn call_automation:app --bind 0.0.0.0:$PORT