#!/bin/sh

dub build -b release || exit 1

code=0

for ex in examples/*
do
    ./bin/medal $ex/network.yml -i $ex/init.yml --workdir=$ex --quiet > /dev/null
    if [ $? -eq 0 ]; then
        echo "success: $ex"
    else
        echo "failed: $ex"
        code=1
    fi
done

exit $code
