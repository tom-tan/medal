#!/bin/sh

if [ ! -x ./bin/medal ]; then
    dub build -b release
fi

for ex in examples/*
do
    ./bin/medal $ex/network.yml -i $ex/init.yml --quiet > /dev/null
    if [ $? -eq 0 ]; then
        echo "success: $ex"
    else
        echo "failed: $ex"
    fi
done
