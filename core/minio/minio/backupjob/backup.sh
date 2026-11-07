#!/bin/sh
set -eu

source_bucket=$${1:?source bucket is required}
destination_bucket=$${2:?destination bucket is required}

# Fail before syncing if either S3 endpoint or bucket is unavailable.
rclone lsd "source:$${source_bucket}" >/dev/null
rclone lsd "destination:$${destination_bucket}" >/dev/null

attempt=1
max_attempts=5
while [ "$${attempt}" -le "$${max_attempts}" ]; do
    echo "Syncing source:$${source_bucket} to destination:$${destination_bucket} -- attempt $${attempt} of $${max_attempts}"

    if rclone sync "source:$${source_bucket}" "destination:$${destination_bucket}" \
        --checksum \
        --fast-list \
        --retries 5 \
        --low-level-retries 20 \
        --retries-sleep 30s \
        --stats 30s \
        --verbose; then
        echo "Sync succeeded"
        exit 0
    fi

    echo "Sync failed; retrying"
    attempt=$$(($${attempt} + 1))
done

echo "Sync failed after $${max_attempts} attempts" >&2
exit 1
