#!/bin/bash

# Variables
SPLUNK_USER="splunk"   
SPLUNK_GROUP="splunk"  
SERVICE_FILE="/etc/systemd/system/Splunk_Status_Monitor.service"
TIMER_FILE="/etc/systemd/system/Splunk_Status_Monitor.timer"

SCRIPT_DIR="/opt/splunk/scripts"
SCRIPT_PATH="$SCRIPT_DIR/Splunk_Status_Monitor.sh"
INSTALL_LOG="/var/log/Splunk_Monitor_Install.log"

echo "======================================================"
echo " Starting Splunk Monitor Installation..."
echo " Target User to run the service : [ $SPLUNK_USER ]"
echo "======================================================" | tee -a $INSTALL_LOG
echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating service for user: $SPLUNK_USER" >> $INSTALL_LOG

# Check if the script exists
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "ERROR: Script $SCRIPT_PATH not found."
    echo "Please move your script to $SCRIPT_DIR before running this setup."
    exit 1
fi

# Set proper ownership and permissions
echo "Setting ownership of script to $SPLUNK_USER:$SPLUNK_GROUP..." | tee -a $INSTALL_LOG
chown $SPLUNK_USER:$SPLUNK_GROUP $SCRIPT_PATH
chmod 750 $SCRIPT_PATH

# Create the service file
echo "Creating systemd service file..." | tee -a $INSTALL_LOG
cat <<EOL | sudo tee $SERVICE_FILE > /dev/null
[Unit]
Description=Splunk Status Monitor Service
After=network.target

[Service]
Type=simple
User=$SPLUNK_USER
Group=$SPLUNK_GROUP
ExecStart=$SCRIPT_PATH
Restart=on-failure
RestartSec=30s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

# Create the timer file
echo "Creating systemd timer file..." | tee -a $INSTALL_LOG
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
echo "Reloading daemon, enabling and starting the timer..." | tee -a $INSTALL_LOG
sudo systemctl daemon-reload
sudo systemctl enable Splunk_Status_Monitor.service
sudo systemctl enable Splunk_Status_Monitor.timer
sudo systemctl start Splunk_Status_Monitor.timer

echo "======================================================"
echo " SUCCESS: Service and timer created successfully."
echo " The monitor will run under the user: $SPLUNK_USER"
echo "======================================================" | tee -a $INSTALL_LOG
