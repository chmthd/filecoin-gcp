#!/bin/bash

# Exit on any error
set -e

# Arguments
IS_MINER=$1

# Variables
LOTUS_REPO="https://github.com/filecoin-project/lotus.git"
LOTUS_DIR="$HOME/lotus-devnet"
GO_VERSION="1.21.7" # Updated Go version to meet Lotus requirements
SECTOR_SIZE="20000"  # 32 GiB in bytes
NUM_SECTORS=1
BUCKET_NAME="filecoin-proving-params-bucket"  # GCS bucket name
PROVING_PARAMS_DIR="/var/tmp/filecoin-proof-parameters"

# Function to check if proving parameters are available locally
are_proving_params_available() {
    local file_count=$(ls $PROVING_PARAMS_DIR/*.params 2>/dev/null | wc -l)
    if [ $file_count -gt 0 ]; then
        return 0 # True: params available
    else
        return 1 # False: params not available
    fi
}

# Function to download proving parameters from GCS if not available locally
download_proving_params() {
    if are_proving_params_available; then
        echo "Proving parameters already available locally, skipping download."
    else
        echo "Downloading proving parameters from GCS..."
        mkdir -p $PROVING_PARAMS_DIR
        gsutil -m cp gs://$BUCKET_NAME/proving-parameters/*.params $PROVING_PARAMS_DIR/ || {
            echo "Failed to download proving parameters. Check GCS permissions and bucket availability."
            exit 1
        }
    fi
}

# Function to upload proving parameters to GCS if not already uploaded
upload_proving_params_to_gcs() {
    if gsutil -q stat gs://$BUCKET_NAME/proving-parameters/*.params; then
        echo "Proving parameters already uploaded to GCS, skipping upload."
    else
        echo "Uploading proving parameters to GCS..."
        gsutil -m cp $PROVING_PARAMS_DIR/*.params gs://$BUCKET_NAME/proving-parameters/
    fi
}

# Update and install dependencies
echo "Updating and installing dependencies..."
sudo apt update
sudo apt install -y build-essential jq pkg-config curl git bzr hwloc ocl-icd-opencl-dev

# Install Go
echo "Installing Go..."
wget -q https://golang.org/dl/go$GO_VERSION.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go$GO_VERSION.linux-amd64.tar.gz
rm go$GO_VERSION.linux-amd64.tar.gz

# Set Go environment variables
echo "Setting Go environment variables..."
echo "export PATH=\$PATH:/usr/local/go/bin" >> ~/.profile
echo "export GOPATH=\$HOME/go" >> ~/.profile
echo "export PATH=\$PATH:\$GOPATH/bin" >> ~/.profile

# Source the updated .profile to make changes take effect
echo "Sourcing profile to apply environment changes..."
source ~/.profile

# Verify Go installation
echo "Verifying Go installation..."
go version || { echo "Go installation failed or PATH not set correctly. Exiting."; exit 1; }

# Install Rust
echo "Installing Rust..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# Source Rust environment
. "$HOME/.cargo/env"

# Verify Rust installation
echo "Verifying Rust installation..."
rustc --version || { echo "Rust installation failed or PATH not set correctly. Exiting."; exit 1; }

# Clone Lotus repository
echo "Cloning Lotus repository..."
mkdir -p $LOTUS_DIR
cd $LOTUS_DIR
git clone $LOTUS_REPO
cd lotus
git checkout releases

# Check for and download proving parameters
download_proving_params

# Build Lotus
echo "Building Lotus binaries..."
make clean all

# Fetch proving parameters if not already available
if ! are_proving_params_available; then
    echo "Fetching proving parameters..."
    ./lotus fetch-params $SECTOR_SIZE
    # Upload to GCS after downloading
    upload_proving_params_to_gcs
fi

if [ "$IS_MINER" = "true" ]; then
    # Pre-seal sectors for the genesis block
    echo "Pre-sealing sectors..."
    ./lotus-seed pre-seal --sector-size $SECTOR_SIZE --num-sectors $NUM_SECTORS

    # Create genesis block
    echo "Creating genesis block..."
    ./lotus-seed genesis new localnet.json

    # Add a pre-mined miner
    echo "Adding pre-mined miner..."
    ./lotus-seed genesis add-miner localnet.json ~/.genesis-sectors/pre-seal-t01000.json

    # Export environment variables
    echo "Exporting environment variables for miner..."
    cat <<'EOL' >> ~/.profile
export LOTUS_PATH=$HOME/.lotus-local-net
export LOTUS_MINER_PATH=$HOME/.lotus-miner-local-net
export LOTUS_SKIP_GENESIS_CHECK=_yes_
export CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"
export CGO_CFLAGS="-D__BLST_PORTABLE__"
EOL

    # Source the updated .profile to make changes take effect
    source ~/.profile

    # Start the client node
    echo "Starting the client node..."
    screen -dmS lotus_client bash -c "cd $LOTUS_DIR/lotus && ./lotus daemon --lotus-make-genesis=devgen.car --genesis-template=localnet.json --bootstrap=false"

    # Wait for client node to start
    sleep 10

    # Import the genesis miner key
    echo "Importing the genesis miner key..."
    cd $LOTUS_DIR/lotus
    ./lotus wallet import --as-default ~/.genesis-sectors/pre-seal-t01000.key

    # Initialize the genesis miner
    echo "Initializing the genesis miner..."
    ./lotus-miner init --genesis-miner --actor=t01000 --sector-size=$SECTOR_SIZE --pre-sealed-sectors=~/.genesis-sectors --pre-sealed-metadata=~/.genesis-sectors/pre-seal-t01000.json --nosync

    # Start the storage provider node
    echo "Starting the storage provider node..."
    screen -dmS lotus_miner bash -c "cd $LOTUS_DIR/lotus && ./lotus-miner run --nosync"

    echo "Miner node setup complete. The miner node is running with 32 GiB sector."
else
    # Export environment variables for client node
    echo "Exporting environment variables for client..."
    echo "export LOTUS_PATH=$HOME/.lotus-local-net" >> ~/.profile

    # Source the updated .profile to make changes take effect
    source ~/.profile

    # Start the client node
    echo "Starting the client node..."
    screen -dmS lotus_client bash -c "cd $LOTUS_DIR/lotus && ./lotus daemon --bootstrap=false"

    echo "Client node setup complete. The client node is running."
fi
