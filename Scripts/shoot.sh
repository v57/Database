#!/bin/zsh
# Launches the Debug app with arguments and screenshots its window once the UI has settled.
# The window comes up without taking focus, so this can run while someone works on the Mac.
# Usage: Scripts/shoot.sh out.png <seconds> -- <app arguments…>
out=$1; wait=$2; shift 3
app=${APP:-.build/xcode/Build/Products/Debug/DatabasePro.app}
log=$(mktemp)
open -n -g --stdout "$log" "$app" --args "$@" --present --present-delay "$wait" -ApplePersistenceIgnoreState YES
sleep 1
pid=$(pgrep -nf "DatabasePro.app/Contents/MacOS/DatabasePro.*--present")
for i in {1..120}; do
  id=$(awk '/^window [0-9]+$/ {print $2; exit}' "$log")
  [ -n "$id" ] && break
  kill -0 $pid 2>/dev/null || break
  sleep 0.5
done
[ -n "$id" ] && screencapture -x -o -l$id "$out" || { echo "no window"; tail -5 "$log"; }
kill $pid 2>/dev/null; while kill -0 $pid 2>/dev/null; do sleep 0.2; done
rm -f "$log"
