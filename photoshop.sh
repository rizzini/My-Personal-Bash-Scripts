#!/bin/sh
param=
while [ -n "$1" ]; do
        param="$param Z:$1"
        shift
done
WINEPREFIX=/home/lucas/.wine_p wine 'C:\Program Files\Adobe\Adobe Photoshop CS6 (64 Bit)\Photoshop.exe' $(echo $param | sed 's,/,\\,g')
