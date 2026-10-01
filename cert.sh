#!/bin/bash

# Create a certs folder relative to your build-deploy.dockerfile
mkdir -p certs
mkcert -install
mkcert -cert-file certs/forgejo.dev.local.pem -key-file certs/forgejo.dev.local-key.pem \
forgejo.dev.local dev.ypto.local sonar.dev.ypto.local rancher.dev.ypto.local
cp "$(mkcert -CAROOT)/rootCA.pem" ./certs/ca.crt
cp "$(mkcert -CAROOT)/rootCA.pem" ./certs/ca-certificates.crt