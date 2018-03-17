#!/bin/bash

P4APPRUNNER=./utils/p4apprunner.py
rm -rf build
mkdir -p build
cp aqua_flow.p4 $1/
pushd $1
tar -czf ../build/p4app.tgz *
popd
sudo python $P4APPRUNNER p4app.tgz --build-dir ./build --manifest p4app.json
