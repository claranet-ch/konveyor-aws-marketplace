#!/bin/sh
snap wait system seed.loaded
snap install microk8s --channel=1.26/stable --classic
usermod -a -G microk8s ubuntu
microk8s status --wait-ready
microk8s enable dns
microk8s enable hostpath-storage
microk8s enable ingress