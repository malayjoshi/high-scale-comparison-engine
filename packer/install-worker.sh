#!/bin/bash
set -euo pipefail

sudo dnf install -y python3 python3-pip amazon-efs-utils

if ! id comparison-worker >/dev/null 2>&1; then
  sudo useradd \
    --system \
    --home-dir /opt/comparison-engine \
    --shell /sbin/nologin \
    comparison-worker
fi

sudo install -d -o comparison-worker -g comparison-worker \
  /opt/comparison-engine/scripts
sudo cp -a /tmp/src /opt/comparison-engine/scripts/src
sudo install -m 0644 /tmp/requirements.txt \
  /opt/comparison-engine/scripts/requirements.txt
sudo install -m 0644 /tmp/comparison-worker.service \
  /opt/comparison-engine/scripts/comparison-worker.service

sudo python3 -m venv /opt/comparison-engine/venv
sudo /opt/comparison-engine/venv/bin/pip install --disable-pip-version-check \
  -r /opt/comparison-engine/scripts/requirements.txt
sudo chown -R comparison-worker:comparison-worker /opt/comparison-engine

sudo install -m 0644 /tmp/comparison-worker.service \
  /etc/systemd/system/comparison-worker.service
sudo systemctl daemon-reload
sudo systemctl disable comparison-worker.service >/dev/null 2>&1 || true

cd /opt/comparison-engine/scripts
sudo -u comparison-worker ../venv/bin/python -c \
  'import boto3, psycopg; import src.handler'

sudo dnf clean all
sudo cloud-init clean --logs
