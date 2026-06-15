#!/bin/bash
set -e

APP="my-nextjs-app"

BLUE_PORT=3000
GREEN_PORT=3001

BLUE_NAME="nextjs_blue"
GREEN_NAME="nextjs_green"

echo "=============================="
echo "🚀 BLUE/GREEN DEPLOY"
echo "=============================="

# detect which slot is free
if docker ps --format '{{.Names}}' | grep -q "$BLUE_NAME"; then
    TARGET_PORT=$GREEN_PORT
    TARGET_NAME=$GREEN_NAME
    ACTIVE_PORT=$BLUE_PORT
else
    TARGET_PORT=$BLUE_PORT
    TARGET_NAME=$BLUE_NAME
    ACTIVE_PORT=$GREEN_PORT
fi

echo "📦 Building image..."
docker build -t $APP:latest .

echo "🚀 Starting new version on port $TARGET_PORT..."

docker run -d \
  --name $TARGET_NAME \
  -p $TARGET_PORT:3000 \
  $APP:latest

echo "⏳ Health check..."
sleep 8

STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$TARGET_PORT || echo "000")

echo "🔎 Status: $STATUS"

if [ "$STATUS" != "200" ]; then
    echo "❌ Failed → rollback"
    docker rm -f $TARGET_NAME
    exit 1
fi

echo "🔁 Restarting nginx container..."
docker restart nginx

echo "🎉 DEPLOY SUCCESS"
