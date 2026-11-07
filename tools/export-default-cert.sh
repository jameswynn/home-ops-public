#!/bin/bash

# export the current default cert
kubectl get -n networking secret default-cert -o yaml | yq '.data."tls.crt"' | base64 -d > server.crt
kubectl get -n networking secret default-cert -o yaml | yq '.data."tls.key"' | base64 -d > server.key

cat server.crt > server.pem
cat server.key >> server.pem
