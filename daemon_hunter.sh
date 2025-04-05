#!/usr/bin/env bash
#
# Script: daemon_hunter.sh
# Purpose: List and manage LaunchAgents/Daemons on macOS, excluding Apple items.
#
# Key features:
# - Main list is split into "User Agents | Loaded", "User Agents | Unloaded", etc.
# - A "*" is appended to any item that is enabled at next startup.
# - Sub-menu with 6 options: Reveal in Finder, Load once, Load persistently, Delete, Return, Quit.

# Directories we scan
USER_AGENT_DIR="$HOME/Library/LaunchAgents"
GLOBAL_AGENT_DIR="/Library/LaunchAgents"
GLOBAL_DAEMON_DIR="/Library/LaunchDaemons"

# Array storing entries as "Category|Label|Status|FilePath"
ALL_ITEMS=()

# ---------------------------------------------------------------------------
# parse_status:
#   Distinguishes "Running" vs. "Loaded" vs. "Unloaded"
#   using 'launchctl list <label>'.
# ---------------------------------------------------------------------------
parse_status() {
  local label="$1"
  if ! launchctl list "$label" &>/dev/null; then
    echo "Unloaded"
    return
  fi

  local pid
  pid="$(launchctl list "$label" 2>/dev/null | awk '{print $1}' | head -n1)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ]; then
    echo "Running"
  else
    echo "Loaded"
  fi
}

# ---------------------------------------------------------------------------
# is_enabled_on_startup:
#   Returns 0 if the item is "enabled" (not in the disabled list), 1 if disabled.
#   Uses modern 'launchctl print-disabled <domain>' approach.
#   Domain:
#     - "gui/<UID>" for user items
#     - "system" for system-wide items
# ---------------------------------------------------------------------------
is_enabled_on_startup() {
  local label="$1"
  local filepath="$2"

  # Determine if user or system domain
  if [[ "$filepath" == "$USER_AGENT_DIR"* ]]; then
    local domain="gui/$(id -u)"
  else
    local domain="system"
  fi

  # Attempt to read the disabled list
  local disabled_line
  disabled_line="$(launchctl print-disabled "$domain" 2>/dev/null | grep "\"$label\" => " || true)"

  # If there's no line for this label, or if line indicates => false, it's enabled
  # Example line: '"com.example.myagent" => false' means it's enabled
  #              '"com.example.myagent" => true'  means it's disabled
  if [[ -z "$disabled_line" ]]; then
    # Not listed => assume it's enabled by default
    return 0
  fi

  if echo "$disabled_line" | grep -q "=> true"; then
    return 1  # disabled
  else
    return 0  # => false => enabled
  fi
}

# ---------------------------------------------------------------------------
# collect_plists:
#   Scans a directory for .plist files, extracts "Label", skips "com.apple.*",
#   determines status, and stores as "Category|Label|Status|FilePath".
# ---------------------------------------------------------------------------
collect_plists() {
  local dir="$1"
  local category="$2"

  [ -d "$dir" ] || return 0

  while IFS= read -r -d '' plist; do
    local label
    label="$(/usr/libexec/PlistBuddy -c "Print :Label" "$plist" 2>/dev/null)"
    [ -z "$label" ] && continue
    [[ "$label" == com.apple.* ]] && continue

    local status
    status="$(parse_status "$label")"

    ALL_ITEMS+=( "$category|$label|$status|$plist" )
  done < <(find "$dir" -maxdepth 1 -type f -name "*.plist" -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# load_data:
#   Populate ALL_ITEMS from standard directories.
# ---------------------------------------------------------------------------
load_data() {
  ALL_ITEMS=()
  collect_plists "$USER_AGENT_DIR"   "User Agent"
  collect_plists "$GLOBAL_AGENT_DIR" "Global Agent"
  collect_plists "$GLOBAL_DAEMON_DIR" "Global Daemon"
}

# ---------------------------------------------------------------------------
# We'll produce a main list in 6 sections:
#  - User Agents | Loaded
#  - User Agents | Unloaded
#  - Global Agents | Loaded
#  - Global Agents | Unloaded
#  - Global Daemons | Loaded
#  - Global Daemons | Unloaded
#
# Asterisk (*) is appended if the item is enabled on next startup.
#
# display_map: an array mapping the displayed index => ALL_ITEMS index
# ---------------------------------------------------------------------------
declare -a DISPLAY_MAP

print_agents() {
  DISPLAY_MAP=()

  local -a user_loaded=()
  local -a user_unloaded=()
  local -a global_loaded=()
  local -a global_unloaded=()
  local -a daemon_loaded=()
  local -a daemon_unloaded=()

  # Sort each item into the appropriate bucket
  for i in "${!ALL_ITEMS[@]}"; do
    IFS="|" read -r category label status path <<< "${ALL_ITEMS[$i]}"

    # "Running" is effectively "Loaded" for grouping
    if [[ "$status" == "Loaded" || "$status" == "Running" ]]; then
      case "$category" in
        "User Agent")   user_loaded+=( "$i" ) ;;
        "Global Agent") global_loaded+=( "$i" ) ;;
        "Global Daemon") daemon_loaded+=( "$i" ) ;;
      esac
    else
      # "Unloaded"
      case "$category" in
        "User Agent")   user_unloaded+=( "$i" ) ;;
        "Global Agent") global_unloaded+=( "$i" ) ;;
        "Global Daemon") daemon_unloaded+=( "$i" ) ;;
      esac
    fi
  done

  # A small helper to print a section. We'll add a "*" if it's enabled next startup.
  print_section() {
    local title="$1"
    shift
    local indices=("$@")  # the ALL_ITEMS indices

    echo "$title"
    for idx_in_all in "${indices[@]}"; do
      IFS="|" read -r cat lbl st fp <<< "${ALL_ITEMS[$idx_in_all]}"

      # Check if it's enabled next startup
      local star=""
      if is_enabled_on_startup "$lbl" "$fp"; then
        star=" *"
      fi

      local display_index=$(( ${#DISPLAY_MAP[@]} + 1 ))
      DISPLAY_MAP[$display_index]="$idx_in_all"
      # Example: "[3] com.qualys.cloud-agent.gui *"
      echo "[$display_index] $lbl$star"
    done
    echo
  }

  echo
  print_section "User Agents | Loaded:"   "${user_loaded[@]}"
  print_section "User Agents | Unloaded:" "${user_unloaded[@]}"
  echo "--------------------------------------"
  print_section "Global Agents | Loaded:"   "${global_loaded[@]}"
  print_section "Global Agents | Unloaded:" "${global_unloaded[@]}"
  echo "--------------------------------------"
  print_section "Global Daemons | Loaded:"   "${daemon_loaded[@]}"
  print_section "Global Daemons | Unloaded:" "${daemon_unloaded[@]}"
}

# ---------------------------------------------------------------------------
# Sub-menu Functions
# ---------------------------------------------------------------------------
open_in_finder() {
  local fp="$1"
  if [ -f "$fp" ]; then
    open -R "$fp"
  else
    echo "File not found: $fp"
  fi
}

load_once() {
  local fp="$1"
  if [[ "$fp" == "$USER_AGENT_DIR"* ]]; then
    launchctl load "$fp" 2>/dev/null || echo "Failed to load agent once."
  else
    sudo launchctl load "$fp" 2>/dev/null || echo "Failed to load system agent/daemon once."
  fi
}

load_persistent() {
  local fp="$1"
  if [[ "$fp" == "$USER_AGENT_DIR"* ]]; then
    launchctl load -w "$fp" 2>/dev/null || echo "Failed to load agent persistently."
  else
    sudo launchctl load -w "$fp" 2>/dev/null || echo "Failed to load system agent/daemon persistently."
  fi
}

# For Delete, we do ephemeral unload first + remove file
delete_agent() {
  local fp="$1"
  echo "WARNING: This will unload (once) and remove the file:"
  echo "  $fp"
  read -rp "Are you sure? (y/N): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    # ephemeral unload
    if [[ "$fp" == "$USER_AGENT_DIR"* ]]; then
      launchctl unload "$fp" 2>/dev/null || true
      rm -f "$fp" || echo "Failed to remove file."
    else
      sudo launchctl unload "$fp" 2>/dev/null || true
      sudo rm -f "$fp" || echo "Failed to remove file."
    fi
    echo "File removed."
  else
    echo "Delete canceled."
  fi
}

# ---------------------------------------------------------------------------
# manage_agent:
#   Shows details + a 6-option menu:
#     1) Reveal in Finder
#     2) Load (once only)
#     3) Load (persistent)
#     4) Delete
#     5) Return to main list
#     6) Quit the script
# ---------------------------------------------------------------------------
manage_agent() {
  local idx_in_all="$1"
  local entry="${ALL_ITEMS[$idx_in_all]}"

  local category label status filepath
  IFS="|" read -r category label status filepath <<< "$entry"

  while true; do
    # We re-check status each time for clarity, though "Load once" won't change the status if it's already loaded
    status="$(parse_status "$label")"

    echo
    echo "----------------------------------"
    echo "Category:  $category"
    echo "Label:     $label"
    echo "Status:    $status"
    echo "File path: $filepath"
    echo "----------------------------------"
    echo "1) Reveal in Finder"
    echo "2) Load (once only)"
    echo "3) Load (persistent)"
    echo "4) Delete (unload + remove file)"
    echo "5) Return to main list"
    echo "6) Quit"
    read -rp "Choose an option: " choice

    case "$choice" in
      1)
        open_in_finder "$filepath"
        ;;
      2)
        load_once "$filepath"
        load_data
        ;;
      3)
        load_persistent "$filepath"
        load_data
        ;;
      4)
        delete_agent "$filepath"
        load_data
        break  # after delete, go back to main list
        ;;
      5)
        break
        ;;
      6)
        echo "Exiting script."
        exit 0
        ;;
      *)
        echo "Invalid choice."
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Main Program
# ---------------------------------------------------------------------------

clear     # clear the page before showing the list of agents

load_data

while true; do
  print_agents
  read -rp "Select an item by number, or 'q' to quit: " sel
  if [[ "$sel" =~ ^[Qq]$ ]]; then
    echo "Exiting."
    exit 0
  fi

  if [[ "$sel" =~ ^[0-9]+$ ]] && [ -n "${DISPLAY_MAP[$sel]}" ]; then
    manage_agent "${DISPLAY_MAP[$sel]}"
  else
    echo "Invalid selection."
  fi
done
