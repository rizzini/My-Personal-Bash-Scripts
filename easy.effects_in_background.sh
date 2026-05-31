#!/bin/bash
if pgrep -x easyeffects; then
    pkill -x easyeffects
else
    easyeffects --hide-window --service-mode --debug & disown
fi
