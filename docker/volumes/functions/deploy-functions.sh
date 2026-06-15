#!/bin/bash
# ================================================================
#  deploy-functions.sh
#  Run this on your OCI VM to deploy all edge functions.
#  Usage: bash deploy-functions.sh
# ================================================================

FUNCTIONS_DIR="$(dirname "$0")"
TARGET="/root/skillima-supabase/volumes/functions"
# Change the above path if your docker-compose is elsewhere:
# TARGET="$HOME/skillima-supabase/volumes/functions"

CONTAINER=$(docker ps --format "{{.ID}}" --filter "ancestor=supabase/edge-runtime" | head -1)

echo "→ Functions source: $FUNCTIONS_DIR"
echo "→ Deploy target:    $TARGET"
echo "→ Edge container:   $CONTAINER"
echo ""

# Create all function directories
FUNCTIONS=(
  "github-username-validate"
  "github-repo-create"
  "github-stage-submit"
  "github-stage-approve"
  "github-stage-changes"
  "github-repo-complete"
  "github-webhook"
  "_shared"
)

for fn in "${FUNCTIONS[@]}"; do
  mkdir -p "$TARGET/$fn"
done

# Copy all files
echo "→ Copying function files..."
cp -r "$FUNCTIONS_DIR"/. "$TARGET/"

echo "→ Verifying files..."
ls "$TARGET/"

# Restart the edge runtime container
echo ""
echo "→ Restarting edge runtime container ($CONTAINER)..."
docker restart "$CONTAINER"

echo ""
echo "→ Waiting 5 seconds for container to start..."
sleep 5

# Verify all functions are inside the container
echo "→ Functions inside container:"
docker exec "$CONTAINER" ls /home/deno/functions/

echo ""
echo "✅ Done. Test with:"
echo "   curl https://api.skillima.com/functions/v1/github-username-validate"
