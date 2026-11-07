#!/bin/bash

USER=ubuntu

SERVERS=(
    muspelheim
    helheim
    niflheim
    svartalfheim
    nidavellir
)

echo "Copying ssh keys to each host"
for server in ${SERVERS[*]}; do
    echo "Copying id to ${USER}@${server}"
    ssh-copy-id ${USER}@${server}
done

for server in ${SERVERS[*]}; do
    if ssh -q -o BatchMode=yes -o ConnectTimeout=5 "${USER}"@"${server}" "true"; then
        echo "SSH into host '${server}' with username '${USER}' was successfull"
    else
        echo "SSH into host '${server}' with username '${USER}'was NOT successful, did you copy over your SSH key?"
        exit 1
    fi
done
