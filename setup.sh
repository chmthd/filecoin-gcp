#!/bin/bash
apt-get update
apt-get install -y git build-essential bzr jq pkg-config curl wget tmux

# Install Go
wget https://go.dev/dl/go1.20.7.linux-amd64.tar.gz
tar -C /usr/local -xzf go1.20.7.linux-amd64.tar.gz
echo "export PATH=\$PATH:/usr/local/go/bin" >> /etc/profile
source /etc/profile

# Clone Lotus and build
git clone https://github.com/filecoin-project/lotus.git /root/lotus
cd /root/lotus
git checkout releases
make 2k
./lotus fetch-params 2048

# Set environment variables
echo "export LOTUS_PATH=/root/.lotus-local-net" >> /etc/profile
echo "export LOTUS_MINER_PATH=/root/.lotus-miner-local-net" >> /etc/profile
echo "export LOTUS_SKIP_GENESIS_CHECK=_yes_" >> /etc/profile
echo "export CGO_CFLAGS_ALLOW=\"-D__BLST_PORTABLE__\"" >> /etc/profile
echo "export CGO_CFLAGS=\"-D__BLST_PORTABLE__\"" >> /etc/profile
source /etc/profile
