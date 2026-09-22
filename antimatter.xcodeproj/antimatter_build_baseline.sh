#!/bin/bash
# Incremental build of the antimatter Debug app into a shared DerivedData dir.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
exec "$DEVELOPER_DIR/usr/bin/xcodebuild" -project /Users/hxmbl/Projects/antimatter/antimatter.xcodeproj \
  -scheme antimatter -configuration Debug \
  -derivedDataPath "/var/folders/8p/t_y147m92yd8s90p1gh_qxl00000gn/T/opencode/antimatter-dd" \
  -quiet build