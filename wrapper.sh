#!/bin/bash

/usr/local/bin/init.sh $@

/usr/local/bin/chisel_linux_arm server --port 80 --proxy http://example.com
