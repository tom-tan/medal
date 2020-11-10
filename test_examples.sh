#!/bin/sh

dub build -b release

for ex in examples/*
do
    ./bin/medal $ex/network.yml -i $ex/init.yml --quiet > /dev/null
    if [ $? -eq 0 ]; then
        echo "success: $ex"
    else
        echo "failed: $ex"
    fi
done
