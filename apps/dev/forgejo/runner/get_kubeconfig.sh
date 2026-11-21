#!/bin/sh

name=forgejo-runner-sa-token
ns=dev
server=$(kubectl config view --minify --output 'jsonpath={.clusters[0].cluster.server}')
ca=$(kubectl get secret/$name -n $ns -o jsonpath='{.data.ca\.crt}')
token=$(kubectl get secret/$name -n $ns -o jsonpath='{.data.token}' | base64 --decode)
namespace=$(kubectl get secret/$name -n $ns -o jsonpath='{.data.namespace}' | base64 --decode)

echo "
apiVersion: v1
kind: Config
clusters:
- name: default-cluster
  cluster:
    certificate-authority-data: ${ca}
    server: ${server}
contexts:
- name: default-context
  context:
    cluster: default-cluster
    namespace: default
    user: default-user
current-context: default-context
users:
- name: default-user
  user:
    token: ${token}
" > buildx.kubeconfig
