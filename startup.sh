#!/bin/bash

# Install required packages
echo "Installing Python packages..."
pip install -r requirements.txt

# Start the application using hypercorn
echo "Starting application..."
python -m hypercorn call_automation:app --bind 0.0.0.0:8000