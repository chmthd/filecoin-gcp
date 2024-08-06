#!/bin/bash

# Exit on any error
set -e

# Constants
MINER_NODE="filecoin-miner"  # Name of your miner node
CLIENT_NODE="filecoin-client"  # Name of your client node
ZONE="us-central1-b"  # GCP Zone for SSH connections

# Environment Variables
LOTUS_PATH="~/.lotus-local-net"
LOTUS_MINER_PATH="~/.lotus-miner-local-net"
LOTUS_SKIP_GENESIS_CHECK="_yes_"
CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"
CGO_CFLAGS="-D__BLST_PORTABLE__"

# Function to run commands on a remote node
run_remote_command() {
    local node_name=$1
    local command=$2

    echo "Running command on $node_name:"
    gcloud compute ssh $node_name --zone $ZONE --command "export LOTUS_PATH=$LOTUS_PATH; export LOTUS_MINER_PATH=$LOTUS_MINER_PATH; export LOTUS_SKIP_GENESIS_CHECK=$LOTUS_SKIP_GENESIS_CHECK; export CGO_CFLAGS_ALLOW=$CGO_CFLAGS_ALLOW; export CGO_CFLAGS=$CGO_CFLAGS; $command"
}

# Function to check client node
check_client_node() {
    echo "Checking client node..."

    # Check synchronization status
    run_remote_command $CLIENT_NODE "lotus sync status"

    # Check connected peers
    run_remote_command $CLIENT_NODE "lotus net peers | wc -l"

    # Verify node info
    run_remote_command $CLIENT_NODE "lotus info"

    # Check wallet balance
    run_remote_command $CLIENT_NODE "lotus wallet balance"

    # List active deals
    run_remote_command $CLIENT_NODE "lotus client list-deals"

    echo "Client node check completed."
}

# Function to check miner node
check_miner_node() {
    echo "Checking miner node..."

    # Check miner status
    run_remote_command $MINER_NODE "lotus-miner info"

    # List sealed sectors
    run_remote_command $MINER_NODE "lotus-miner sectors list"

    # Monitor active deals
    run_remote_command $MINER_NODE "lotus-miner storage-deals list"

    # Check sector lifecycle for the first 5 sectors
    for i in {0..4}; do
        run_remote_command $MINER_NODE "lotus-miner sectors status --log $i"
    done

    echo "Miner node check completed."
}

# Main script execution
echo "Starting Filecoin network verification..."

# Verify both client and miner nodes
check_client_node
check_miner_node

echo "Filecoin network verification completed successfully."
