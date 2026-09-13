#!/bin/bash

MC_CONFIG_DIR=${MC_CONFIG_DIR:-/minio}

mirror_with_retry() {
    # Maximum number of attempts
    max_attempts=5
    attempt=1

    # Loop until the command succeeds or the maximum attempts are reached
    while [[ $attempt -le $max_attempts ]]; do
        echo "Mirroring '$1' to '$2' -- Attempt $attempt of $max_attempts..."

        mc mirror --overwrite --remove --retry $1 $2

        # Check the exit status of the command
        if [[ $? -eq 0 ]]; then
            echo "Command succeeded!"
            break
        else
            echo "Command failed. Retrying..."
        fi

        ((attempt++))
    done
}

set -x
mirror_with_retry $1 $2
