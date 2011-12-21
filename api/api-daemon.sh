#!/bin/bash

socat -T 30 TCP4-LISTEN:8080,fork,reuseaddr EXEC:./api-server.sh,sighup,sigint,sigquit

