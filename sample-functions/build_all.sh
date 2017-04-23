#!/usr/bin/env bash

export current=$(pwd)

for dir in `ls`;
do
    test -d "$dir" || continue
    cd $dir
    echo $dir

    if [ -e ./build.sh ]
    then
        ./build.sh
    fi
    cd ..
done

> func.yaml

for dir in `ls`;
do
    test -d "$dir" || continue
    if [ -e $dir/func.yaml ]
    then
        cat $dir/func.yaml >> func.yaml
    fi
done
