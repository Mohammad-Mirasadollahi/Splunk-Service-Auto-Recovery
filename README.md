# Splunk Service Auto Recovery

⚠️ **IMPORTANT: Non-Root User Requirement**
In modern and secure Splunk environments, running Splunk services as the `root` user is strictly prohibited. This script is fully optimized to run under a specific non-root user (e.g., `splunk`). The installation script will automatically set up the systemd service to execute under the defined user and will adjust the required file permissions accordingly. **You must ensure the `SPLUNK_USER` variable in the installation script matches your actual Splunk user.**

---

This script is designed to monitor and automatically recover a Splunk service. It continuously checks (30s) the status of the Splunk service by verifying its response on critical ports (443 and 8089) and ensuring the `splunkd` process is running. If any of these checks fail, the script logs the specific issue and attempts to recover the service by restarting it. The script makes multiple attempts to start or restart the service and logs each step with timestamps, target user, and unique process IDs. It runs in an infinite loop, ensuring the Splunk service remains operational with minimal downtime.

**Note:** These scripts were developed with the help of ChatGPT and have been tested successfully without any issues.

## Script Workflow

1. **Initial Service Check**: The script checks the Splunk service status by:
   - **Port 443 Check**: Ensuring the service responds with "303 See Other" and "Server: Splunkd."
   - **Port 8089 Check**: Ensuring the service responds with "200 OK" and "Server: Splunkd."
   - **Splunkd Process Check**: Verifying that the `splunkd` process is running.
   - If any check fails, the issue is logged, and the script waits 3 minutes.

2. **Recheck Service Status**: After waiting, the script rechecks the service:
   - If still down, it logs the issue and attempts to start the service.

3. **First Start Attempt**: The script starts the service and waits 3 minutes:
   - If the service remains down, it logs the failure and tries to start the service again.

4. **Second Start Attempt**: The script starts the service again and waits 3 minutes:
   - If unsuccessful, it logs the issue and attempts a full restart.

5. **Restart Attempt**: The script restarts the Splunk service and waits 3 minutes:
   - A final check is done. If the service is still down, it logs the failure; if successful, it logs that the service is up.

6. **Loop Continues**: The script waits 30 seconds and repeats the monitoring loop.

## Variables
In the context of the scripts, there are several variables that you can (and should) change based on your environment.

**In the Installation Script (`Splunk_Status_Monitor_Service.sh`):**
- **SPLUNK_USER=**`"splunk"`: The specific OS user running your Splunk instance.
- **SPLUNK_GROUP=**`"splunk"`: The specific OS group for your Splunk instance.
- **SCRIPT_DIR=**`"/opt/splunk/scripts"`: The directory where the monitoring script is located.

**In the Monitoring Script (`Splunk_Status_Monitor.sh`):**
- **SPLUNK_PATH=**`"/opt/splunk/bin"`: Splunk binary installation path.
- **LOG_FILE=**`"/opt/splunk/var/log/Splunk_Status_Monitor.log"`: Script Log file path (Moved here to ensure the `splunk` user has write permissions).
