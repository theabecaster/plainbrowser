#!/bin/zsh
# Sets an iPhone Duo simulator's fold state, or rotates it, by pressing Device Hub's buttons
# (Xcode's Device Hub has no command line for the fold). Only the named simulator is touched.
#   scripts/duo-fold.sh <simulator name> Closed|"Partially Open"|Open|"Rotate Right"
# Needs Accessibility access for the terminal (System Settings > Privacy & Security >
# Accessibility), because it drives Device Hub through System Events. The simulator must be booted.
set -euo pipefail
[[ $# -eq 2 ]] || { print -u2 "usage: $0 <simulator name> Closed|'Partially Open'|Open|'Rotate Right'"; exit 1; }
name=$1
state=$2
case $state in
  Closed|"Partially Open"|Open|"Rotate Right") ;;
  *) print -u2 "unknown state: $state"; exit 1 ;;
esac

open -a /Applications/Xcode.app/Contents/Applications/DeviceHub.app
sleep 2
timeout 60 osascript - "$name" "$state" <<'OSA'
on run argv
  set simName to item 1 of argv
  set foldState to item 2 of argv
  tell application "System Events" to tell process "DeviceHub"
    -- A closed or hidden window comes back from the Window menu.
    if (count of windows) is 0 then
      repeat with m in menu items of menu "Window" of menu bar 1
        try
          if (name of m) starts with simName then click m
        end try
      end repeat
      delay 1.5
    end if
    set w to window 1
    set sidebar to outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of splitter group 1 of group 1 of w
    repeat with r in rows of sidebar
      try
        if (value of static text 1 of UI element 1 of r) is simName then select r
      end try
    end repeat
    delay 1.5
    if name of window 1 does not start with simName then error "Device Hub shows " & (name of window 1) & ", not " & simName
    set controls to group 3 of splitter group 1 of group 1 of splitter group 1 of group 1 of window 1
    repeat with b in (buttons of controls)
      if (value of attribute "AXHelp" of b) is foldState then
        click b
        return foldState
      end if
    end repeat
    error "Device Hub has no " & foldState & " button for " & simName
  end tell
end run
OSA
