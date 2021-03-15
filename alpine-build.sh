#!/bin/sh

apk --no-cache add dub ldc gcc musl-dev git

dub build -b release-static || exit 1
strip bin/medal

dub build -b release-static --single net2dot.d || exit 1
strip bin/net2dot
