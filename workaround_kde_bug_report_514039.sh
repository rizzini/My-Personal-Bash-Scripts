#!/bin/bash
#https://bugs.kde.org/show_bug.cgi?id=514039
sleep 5

copyq --start-server &
pid_copyq=$!

keepassxc &
pid_keepassxc=$!

easyeffects --hide-window --service-mode &
pid_easyeffects=$!

sleep 3

while ! pgrep -x copyq; do
    kill -9 $pid_copyq
    copyq --start-server &
    pid_copyq=$!
    sleep 2
done &

while ! pgrep -x keepassxc; do
    kill -9 $pid_keepassxc
    keepassxc &
    pid_keepassxc=$!
    sleep 2
done &

while ! pgrep -x easyeffects; do
    kill -9 $pid_easyeffects
    easyeffects --hide-window --service-mode &
    pid_easyeffects=$!
    sleep 2
done &
