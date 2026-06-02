#!/bin/zsh
# Helper: after you have created the Xcode project as described in README,
# you can run this to do a quick archive or just remind steps.
set -e

echo "This is not a full build script (Xcode project required)."
echo "Follow the numbered steps in README.md exactly."
echo
echo "After the project is set up, a typical build command from terminal:"
echo "  xcodebuild -project MKVQuickLook.xcodeproj -scheme MKVQuickLook -configuration Release build"
echo
echo "The resulting .app will be in ~/Library/Developer/Xcode/DerivedData/.../Build/Products/Release/MKVQuickLook.app"
echo "Double-click it, then test with your .mkv files + Spacebar."
echo
echo "To force the extensions to re-register after changes:"
echo "  qlmanage -r && qlmanage -r cache"
echo
echo "Good luck — your custom ffmpeg codecs will now be a first-class citizen of Finder previews."
