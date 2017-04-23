#!/usr/bin/env bash

export GOPATH=`pwd`
go get -v -d
go build
