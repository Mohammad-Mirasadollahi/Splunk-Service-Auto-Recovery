#!/bin/bash

# Log file path
LOG_FILE="/var/log/Splunk_Status.log"

# Splunk installation path
SPLUNK_PATH="/opt/splunk/bin"

# Function to generate process_id
generate_process_id() {
    openssl rand -hex 3 | tr 'a-f' 'A-F'
}

# Function to log messages with timestamp and process_id
log_message() {
    local message="$1"
    local process_id="$2"
    echo "timestamp=\"$(date '+%Y-%m-%d %H:%M:%S %Z')\" process_id=\"$process_id\" message=\"$message\"" >> $LOG_FILE
}

# Function to check the service status
check_service() {
    # Check service status on port 443 (expecting "303 See Other" and "Server: Splunkd")
    curl_443=$(curl -k --silent --head https://127.0.0.1)
    echo "$curl_443" | grep -q "303 See Other" && echo "$curl_443" | grep -q "Server: Splunkd"
    local status_443=$?

    # Check service status on port 8089 (expecting "200 OK" and "Server: Splunkd")
    curl_8089=$(curl -k --silent --head https://127.0.0.1:8089)
    echo "$curl_8089" | grep -q "200 OK" && echo "$curl_8089" | grep -q "Server: Splunkd"
    local status_8089=$?

    # Check if splunkd is running
    $SPLUNK_PATH/splunk status | grep "splunkd is not running." > /dev/null
    local splunk_status=$?

    # Return 0 if all checks pass, otherwise return 1
    if [ $status_443 -eq 0 ] && [ $status_8089 -eq 0 ] && [ $splunk_status -ne 0 ]; then
        return 0
    else
        # Log which check failed
        if [ $status_443 -ne 0 ]; then
            log_message "Service down: port 443 check failed." "$1"
        elif [ $status_8089 -ne 0 ]; then
            log_message "Service down: port 8089 check failed." "$1"
        elif [ $splunk_status -eq 0 ]; then
            log_message "Service down: splunkd is not running." "$1"
        fi
        return 1
    fi
}

# Function to start Splunk service
start_splunk() {
    log_message "Starting Splunk service..." "$1"
    $SPLUNK_PATH/splunk start
}

# Function to restart Splunk service
restart_splunk() {
    log_message "Restarting Splunk service..." "$1"
    $SPLUNK_PATH/splunk restart
}

# Main loop
while true; do
    process_id=$(generate_process_id)
    check_service "$process_id"
    if [ $? -ne 0 ]; then
        log_message "Service is down. Waiting for 3 minutes before rechecking." "$process_id"
        sleep 180  # Wait 3 minutes before rechecking
        
        # Recheck service status after waiting
        check_service "$process_id"
        if [ $? -ne 0 ]; then
            log_message "Service is still down after waiting. Attempting to start Splunk." "$process_id"

            start_splunk "$process_id"
            sleep 180  # Wait 3 minutes for the service to have time to start up
            
            check_service "$process_id"
            if [ $? -ne 0 ]; then
                log_message "Service is still down after first start attempt. Attempting to start Splunk again." "$process_id"
                
                start_splunk "$process_id"  # Attempt to start Splunk again
                sleep 180  # Wait 3 minutes for the service to have time to start up again
                
                check_service "$process_id"
                if [ $? -ne 0 ]; then
                    log_message "Service is still down after second start attempt. Attempting to restart Splunk." "$process_id"
                    
                    restart_splunk "$process_id"  # Attempt to restart Splunk
                    sleep 180  # Wait 3 minutes for the service to have time to restart
                    
                    check_service "$process_id"
                    if [ $? -ne 0 ]; then
                        log_message "Service is still down after restart." "$process_id"
                    else
                        log_message "Service is up after restart." "$process_id"
                    fi
                else
                    log_message "Service is up after second start attempt." "$process_id"
                fi
            else
                log_message "Service is up after first start attempt." "$process_id"
            fi
        fi
    fi
    sleep 30  # Wait 30 seconds before the next check
done
