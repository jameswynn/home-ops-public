#!/bin/env bash

export LIST=$(kubectl get pods --all-namespaces -o jsonpath="{.items[*].spec['initContainers', 'containers'][*].image}" | tr -s '[[:space:]]' '\n' | ugrep -o '^([a-z0-9]+(\.+[a-z0-9]+)+)' | ugrep -v 'docker.io' | sort | uniq | paste -sd '|')

kubectl get pods --all-namespaces -o jsonpath="{.items[*].spec['initContainers', 'containers'][*].image}" | tr -s '[[:space:]]' '\n' | grep -v "^($LIST)/" | sort | uniq -c
