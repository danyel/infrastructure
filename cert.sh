#!/bin/bash

# Create a certs folder relative to your build-deploy.dockerfile
mkdir -p certs
mkcert -install
mkcert -cert-file certs/forgejo.dev.dev.pem -key-file certs/forgejo.dev.dev-key.pem \
forgejo.dev.dev dev.ypto.dev sonar.dev.ypto.dev rancher.dev.ypto.dev
cp "$(mkcert -CAROOT)/rootCA.pem" ./certs/ca.crt
cp "$(mkcert -CAROOT)/rootCA.pem" ./certs/ca-certificates.crt