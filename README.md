# Autonomous Bash Scripts for the Android Linux Development Environment (LDE) Developer Options Feature

### <Self-Host WordPress on Android with Cloudflare Tunnel>

This repository provides a single script that installs Docker, MariaDB, WordPress, and Cloudflared on an Android device running the Linux Development Environment (LDE). Once configured, the stack runs under systemd so your site comes online whenever you open the Terminal app. Tested on a Pixel 6a (Android 15 Beta build BP41.250916.012), but it should work on any device with LDE support.

## Requirements
- Cloudflare account (free tiers work)
- Active domain managed by Cloudflare
- Cloudflare API token with the permissions shown in this screenshot: <img width="913" height="610" alt="cloudflare_API_TOKEN" src="https://github.com/user-attachments/assets/b23feefe-7a7c-41b3-9d63-d1b5fd112e76" />
- Android phone running Android 15 or later with the Linux Development Environment feature

## Prepare Your Android Device
1. Open **Settings → About Phone → Build Number**, then tap the build number seven times quickly to enable developer options.
2. Navigate to **Settings → System → Developer options → Linux development environment** and toggle it **ON**.
3. Open the app drawer, launch the **Terminal** app, allow its notifications, and tap **Install** in the bottom-right corner.
4. Wait until the terminal finishes setting up; you should see a green prompt similar to `droid@debian:~$`.

## Run the Installer
1. Paste the following command into the terminal and press **Enter**:

    ```bash
    sudo apt update; sudo apt upgrade -y; sudo apt install -y curl; curl -fsSL https://raw.githubusercontent.com/charettep/lde-scripts/main/wp+cf.sh -o /tmp/wp+cf.sh; chmod +x /tmp/wp+cf.sh; sudo /tmp/wp+cf.sh
    ```

2. When prompted, paste your Cloudflare API token (it must match the permissions shown above) and press **Enter**.
3. Enter the full hostname where you want your WordPress site to be reachable—for example `blog.example.com`—and press **Enter**. Make sure the base domain is active in your Cloudflare account.
4. Approve each system prompt to open network ports for Docker, MariaDB, and Cloudflared. Declining these prompts will interrupt the installation.

## After Installation
- Visit the hostname you provided from any browser to complete WordPress’s initial setup wizard (takes about five seconds).
- The services are registered as systemd units, so the site starts whenever the Terminal app is open and stops when you close it.
- Re-run the script any time you need to update or reinstall the stack; it is safe to execute multiple times.
