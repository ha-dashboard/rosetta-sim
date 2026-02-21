#!/bin/bash
# Kill all RosettaSim-related processes safely
# Uses full path matching to avoid killing system processes

for pattern in \
    "/Users/ashhopkins/Projects/rosetta.*rosettasim_broker" \
    "/Applications/Xcode-8.3.3.app.*backboardd" \
    "/Applications/Xcode-8.3.3.app.*SpringBoard" \
    "/Applications/Xcode-8.3.3.app.*assertiond" \
    "HA.Dashboard" \
    "run_full.sh"; do
    pgrep -f "$pattern" 2>/dev/null | while read p; do
        kill -9 "$p" 2>/dev/null
    done
done

sleep 1
rm -f /tmp/rosettasim_framebuffer* /tmp/rosettasim_context_id \
      /tmp/rosettasim_broker.pid /tmp/rosettasim_test.log \
      /tmp/rosettasim_test_pid /tmp/rosettasim_app_framebuffer 2>/dev/null

echo "RosettaSim processes and temp files cleaned"
