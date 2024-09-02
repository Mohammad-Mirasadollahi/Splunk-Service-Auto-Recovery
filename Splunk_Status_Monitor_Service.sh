#!/bin/bash

# Variables
SERVICE_FILE="/etc/systemd/system/Splunk_Status_Monitor.service"
TIMER_FILE="/etc/systemd/system/Splunk_Status_Monitor.timer"
SCRIPT_PATH="/root/scripts/Splunk_Status_Monitor.sh"

# Check if the script exists
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Script $SCRIPT_PATH not found. Please check the correct path."
    exit 1
fi

# Give execution permissions to the script
chmod 750 $SCRIPT_PATH

# Create the service file
echo "Creating service file..."
cat <<EOL | sudo tee $SERVICE_FILE > /dev/null
[Unit]
Description=Splunk Status Monitor Service
After=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH
Restart=on-failure
RestartSec=30s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

# Create the timer file
echo "Creating timer file..."
cat <<EOL | sudo tee $TIMER_FILE > /dev/null
[Unit]
Description=Run Splunk Status Monitor 5 minutes after boot

[Timer]
OnBootSec=5min
Unit=Splunk_Status_Monitor.service

[Install]
WantedBy=timers.target
EOL

# Enable and start the service and timer
echo "Enabling and starting the service and timer..."
sudo systemctl daemon-reload
sudo systemctl enable Splunk_Status_Monitor.service
sudo systemctl enable Splunk_Status_Monitor.timer
sudo systemctl start Splunk_Status_Monitor.timer

echo "Service and timer have been successfully created and enabled."
