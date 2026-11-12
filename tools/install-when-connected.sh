#!/bin/bash
# Waits for Mohamed's iPhone to come back within reach of this Mac, then
# installs the Release build that is already sitting in DerivedData.
# Gives up after four hours rather than polling forever.
UDID=00008101-000529043A78001E
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/ROVA-*/Build/Products/Release-iphoneos/ROVA.app 2>/dev/null | head -1)
[ -z "$APP" ] && { echo "no Release build found"; exit 1; }
for i in $(seq 1 240); do
  if xcrun devicectl list devices 2>/dev/null | grep -q "$UDID.*connected"; then
    echo "device reachable, installing…"
    if xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | grep -q "App installed"; then
      echo "INSTALLED $(date '+%H:%M')"
      exit 0
    fi
    echo "install attempt failed, retrying"
  fi
  sleep 60
done
echo "gave up after 4 hours — iPhone never came back within reach"
exit 2
