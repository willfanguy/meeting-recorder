#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Extract Meeting Tasks
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon ✅
# @raycast.packageName Meeting Recorder
# @raycast.description Scan recent meetings for pending tasks and create Task Notes

# Open terminal with claude agent
osascript -e 'tell application "Terminal"
    activate
    do script "cd ~/Repos/personal && claude --agent meeting-tasks-extractor"
end tell'

echo "Opened Terminal with meeting-tasks-extractor agent"
