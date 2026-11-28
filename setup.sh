#!/bin/bash

# Tools from apt
APT_TOOLS="\
    ansible \
    direnv \
    age \
    task"

# Tools from arkade
ARK_TOOLS="\
    kubectl \
    helm \
    sops \
    flux \
    jq \
    k9s \
    kube-bench \
    kustomize \
    mc \
    yq"

echo "Installing necessary tools: "
sudo apt install -y ${APT_TOOLS}

echo "Installing Arkade"
curl -sLS https://get.arkade.dev | sudo sh

echo "Installing Arkade packages"
arkade get ${ARK_TOOLS}

if grep -Fxq 'eval "$(direnv hook zsh)"' ~/.zshrc ; then
    echo "direnv already in ~/.zshrc"
else
    echo 'adding direnv to ~/.zshrc'
    echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc
fi

echo "Allow the project .envrc"
direnv allow ./.envrc
echo "Allow the ansible .envrc config"
direnv allow ./ansible/.envrc
