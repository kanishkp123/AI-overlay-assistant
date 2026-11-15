#!/bin/bash
# Build script for AI Overlay Assistant
# Requires: Xcode command line tools + Tesseract

set -e

echo "🔨 Building AI Overlay Assistant..."

# Check for Tesseract
if ! command -v tesseract &> /dev/null; then
    echo "⚠️  Tesseract not found. Install with: brew install tesseract"
    exit 1
fi

echo "✅ Tesseract found: $(tesseract --version | head -1)"

# Build with xcodebuild
xcodebuild -scheme AIOverlayAssistant \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -quiet \
    build

echo "✅ Build succeeded!"
echo "📦 App location: ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/AIOverlayAssistant"