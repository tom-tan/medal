#!/bin/sh

dub build -b release || exit 1

code=0

for ex in examples/*
do
    dir=$(head -c10 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | cut -c 1-10)
    mkdir -p $dir
    ./bin/medal $ex/network.yml -i $ex/init.yml --workdir=$ex --tmpdir=$dir/tmp --leave-tmpdir --log=$dir/medal.json > /dev/null
    if [ $? -eq 0 ]; then
        echo "success: $ex"
        rm -rf $dir
    else
        echo "failed: $ex (see: $dir)"
        code=1
    fi
done

exit $code
