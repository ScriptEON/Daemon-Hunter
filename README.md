# Daemon-Hunter
Terminal utility to manage Launch Agents and Launch Daemons on macOS


Script: daemon_hunter.sh
Purpose: List and manage LaunchAgents/Daemons on macOS, excluding macOS built-in processes.

Key features:
* Main list is split into "User Agents | Loaded", "User Agents | Unloaded", etc.
* A "*" is appended to any item that is enabled at next startup.
* Sub-menu with 6 options: Reveal in Finder, Load once, Load persistently, Delete, Return, Quit.
