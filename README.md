# Splunk Service Auto Recovery
This script is designed to monitor and automatically recover a Splunk service. It continuously checks the status of the Splunk service by verifying its response on critical ports (443 and 8089) and ensuring the splunkd process is running. If any of these checks fail, the script logs the specific issue and attempts to recover the service by restarting it. The script makes multiple attempts to start or restart the service and logs each step with timestamps and unique process IDs. It runs in an infinite loop, ensuring the Splunk service remains operational with minimal downtime.

# Script Workflow

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
In the context of the script, there are several variables that you can (optional) change it based on your environment.

**SPLUNK_PATH=**"/splunk/opt/splunk/bin": Splunk installation path

**LOG_FILE=**"/var/log/Splunk_Status.log": Script Log file path

# Quick Start

**Quick Start Guide:**

0. Make sure you are login as root.
   
 ```
 sudo -i
   ```

1. First, download the repository.
   
 ```
 git clone https://github.com/Mohammad-Mirasadollahi/Splunk-Service-Auto-Recovery.git
   ```
2. Move all of them into the `/root/scripts` directory. If the directory does not exist, create it.

 ```
cd Splunk-Service-Auto-Recovery
mkdir -p /root/scripts
mv Splunk-Service-Auto-Recovery_Scripts.tar.gz /root/scripts/
   ```
3. Go to the /root/scripts/ directory and then, run the following command.
```
cd /root/scripts/
tar xzvf Splunk-Service-Auto-Recovery_Scripts.tar.gz
   ```
4. Then, just run the following command.
```
bash ./Splunk_Status_Monitor_Service.sh
   ```
5. Finally, check the service status.
```
service Splunk_Status_Monitor status
   ```
