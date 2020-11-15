#!/bin/sh

apk --no-cache add dub ldc gcc musl-dev
dub build -b release-static
