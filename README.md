# UbuntuSetup
This repo provides two Ubuntu Linux setup scripts, which will help you setup your newly installed Ubuntu Desktop (preferrably through my super sketchy looking USB-stick hehehe).

## What's in here

- `scripts/setup/setup-ubuntu.sh` — provisions a **work** laptop: Docker, Git and other core dev tools, Google Chrome, IntelliJ IDEA Community Edition, Twingate, and disables the GNOME Tiling Assistant extension.
- `scripts/setup/setup-ubuntu-personal.sh` — provisions a **personal** laptop: Docker, Git, Python, Firefox, and Visual Studio Code, and disables the GNOME Tiling Assistant extension. No Twingate.

## Before you run anything

- A fresh install of **Ubuntu 26.04 LTS**, already installed and logged into the desktop.
- An active internet connection (the scripts download packages and installers).
- Administrator (sudo) access on the machine.
- Run the scripts from a terminal, not by double-clicking them.

## Running the work setup script

```
cd scripts/setup
sudo ./setup-ubuntu.sh
```

Run it with `sudo`, not logged in as `root` directly, so the script can correctly detect your normal desktop user account and apply desktop-user actions (like disabling the Tiling Assistant extension) to that user instead of root.

A couple of things it may ask you to handle manually instead of guessing:
- If the current IntelliJ IDEA Community Edition download URL can't be resolved automatically, it will stop and tell you to paste the official JetBrains Linux `.tar.gz` URL into the `INTELLIJ_DOWNLOAD_URL` variable near the top of the script.
- If Docker doesn't yet publish an apt repository for your Ubuntu release, it will stop rather than fall back to an unsupported one — check https://docs.docker.com/engine/install/ubuntu/ and re-run once it's available.

After it finishes, you still need to:
- Log out and back in (or reboot) so your Docker group membership takes effect.
- Set your Git identity (`git config --global user.name` / `user.email`).
- Run `sudo twingate setup` and start the Twingate desktop client.
- Install Outlook and Teams as Progressive Web Apps through Chrome, if required.

## Running the personal setup script

```
cd scripts/setup
sudo ./setup-ubuntu-personal.sh
```

Same requirements as above (run with `sudo`, not as `root`). After it finishes, set your Git identity and log out/back in so Docker works without `sudo`.