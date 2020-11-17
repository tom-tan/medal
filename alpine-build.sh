#!/bin/sh

apk --no-cache add dub ldc gcc musl-dev

dub build -b release-static
strip bin/medal

dub build -b release-static --single net2dot.d
strip bin/net2dot
