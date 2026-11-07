#!/bin/bash

bucket=$1
policyname=${bucket}
username=${2:-${bucket}}
password=${3:-$(openssl rand -base64 30)}
server=${SERVER:-nas}

echo "Creating bucket '${bucket}' on server '${server}' with username: '${username}' and password '${password}'"

policyfile=$(mktemp /tmp/tempfile.XXXXXX)

sed "s/<BUCKET>/${bucket}/g" s3-policy.json > ${policyfile}

mc mb ${server}/${bucket}
mc admin user add ${server} ${username} ${password}
mc admin policy create ${server} ${policyname} ${policyfile}
mc admin policy attach ${server} ${bucket} user=${username}
