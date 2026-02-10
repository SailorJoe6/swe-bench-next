#!/bin/bash
# Tag ARM64 images with SWE-agent expected format
#
# SWE-bench builds images as: sweb.eval.arm64.repo__instance:latest
# SWE-agent expects: docker.io/swebench/sweb.eval.arm64.repo_1776_instance:latest
#
# This script tags all images appropriately.

set -e

echo "Tagging ARM64 images for SWE-agent compatibility..."

# Count total images
TOTAL=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "^sweb.eval.arm64" | wc -l)
echo "Found $TOTAL ARM64 instance images to tag"

TAGGED=0
SKIPPED=0

# Iterate through all ARM64 instance images
docker images --format "{{.Repository}}:{{.Tag}}" | grep "^sweb.eval.arm64" | while read IMAGE; do
    # Extract repo name
    REPO=$(echo "$IMAGE" | cut -d: -f1)
    TAG=$(echo "$IMAGE" | cut -d: -f2)

    # Convert double underscore to _1776_ and add docker.io/swebench/ prefix
    # Example: sweb.eval.arm64.apache__druid-13704:latest
    #       -> docker.io/swebench/sweb.eval.arm64.apache_1776_druid-13704:latest
    INSTANCE_NAME=$(echo "$REPO" | sed 's/sweb.eval.arm64.//')
    NEW_NAME="docker.io/swebench/sweb.eval.arm64.${INSTANCE_NAME//__/_1776_}"

    # Check if tag already exists
    if docker images "$NEW_NAME:$TAG" --format "{{.Repository}}" | grep -q "$NEW_NAME"; then
        echo "  ⏭️  Skipping $INSTANCE_NAME (already tagged)"
        ((SKIPPED++))
    else
        echo "  ✓ Tagging $INSTANCE_NAME"
        docker tag "$IMAGE" "$NEW_NAME:$TAG"
        ((TAGGED++))
    fi
done

echo ""
echo "✅ Tagging complete!"
echo "   Tagged: $TAGGED images"
echo "   Skipped: $SKIPPED images (already tagged)"
echo ""
echo "Verify with: docker images | grep 'swebench/sweb.eval.arm64'"
