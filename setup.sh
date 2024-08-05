#!/bin/bash

# Exit on any error
set -e

# Configuration
PROJECT_ID="sit724"                 # Replace with your GCP project ID
ZONE="us-central1-a"                # Choose your preferred zone
NETWORK="filecoin-network"          # Custom network name
SUBNET="filecoin-subnet"            # Custom subnet name
REGION="us-central1"                # Region for the subnet
IMAGE_FAMILY="ubuntu-2004-lts"      # Ubuntu 20.04 LTS image
IMAGE_PROJECT="ubuntu-os-cloud"
MINER_INSTANCE_NAME="filecoin-miner"
CLIENT_INSTANCE_NAME="filecoin-client"
MACHINE_TYPE_MINER="e2-standard-4"  # 4 vCPUs, 16 GiB memory
MACHINE_TYPE_CLIENT="e2-standard-2" # 2 vCPU, 8 GiB memory
DISK_SIZE_MINER="64"                # 64 GiB for miner
DISK_SIZE_CLIENT="32"               # 32 GiB for client
PREEMPTIBLE=false                   # Set to true if you want preemptible instances
SSH_KEY_PATH="$HOME/.ssh/google_compute_engine.pub"  # Path to the SSH public key

# Function to check if a resource exists
resource_exists() {
    local resource_type=$1
    local resource_name=$2
    local result=$(gcloud compute $resource_type list --project=$PROJECT_ID --filter="name=($resource_name)" --format="get(name)")
    if [ "$result" == "$resource_name" ]; then
        return 0 # True: resource exists
    else
        return 1 # False: resource does not exist
    fi
}

# Create a VPC network if it doesn't exist
if resource_exists "networks" $NETWORK; then
    echo "VPC network '$NETWORK' already exists, skipping creation."
else
    echo "Creating VPC network..."
    gcloud compute networks create $NETWORK \
        --project=$PROJECT_ID \
        --subnet-mode=custom
fi

# Create a subnet in the VPC network if it doesn't exist
if resource_exists "networks subnets" $SUBNET; then
    echo "Subnet '$SUBNET' already exists, skipping creation."
else
    echo "Creating subnet..."
    gcloud compute networks subnets create $SUBNET \
        --project=$PROJECT_ID \
        --region=$REGION \
        --network=$NETWORK \
        --range=10.0.0.0/24
fi

# Configure firewall rules (check and create if necessary)
if resource_exists "firewall-rules" "filecoin-allow-internal"; then
    echo "Firewall rule 'filecoin-allow-internal' already exists, skipping creation."
else
    echo "Configuring internal firewall rules..."
    gcloud compute firewall-rules create filecoin-allow-internal \
        --project=$PROJECT_ID \
        --network=$NETWORK \
        --allow tcp,udp,icmp \
        --source-ranges=10.0.0.0/24
fi

if resource_exists "firewall-rules" "filecoin-allow-external"; then
    echo "Firewall rule 'filecoin-allow-external' already exists, skipping creation."
else
    echo "Configuring external firewall rules..."
    gcloud compute firewall-rules create filecoin-allow-external \
        --project=$PROJECT_ID \
        --network=$NETWORK \
        --allow tcp:22,tcp:1234,tcp:1347 \
        --source-ranges=0.0.0.0/0
fi

# Function to create or reset a VM instance
create_or_reset_instance() {
    local INSTANCE_NAME=$1
    local MACHINE_TYPE=$2
    local DISK_SIZE=$3
    local PREEMPTIBLE_FLAG=""

    if [ "$PREEMPTIBLE" = true ]; then
        PREEMPTIBLE_FLAG="--preemptible"
    fi

    if resource_exists "instances" $INSTANCE_NAME; then
        echo "Instance $INSTANCE_NAME already exists. Deleting it to reset..."
        gcloud compute instances delete $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID --quiet
        echo "Instance $INSTANCE_NAME deleted."
    fi

    echo "Creating VM instance: $INSTANCE_NAME with disk size $DISK_SIZE GiB..."
    gcloud compute instances create $INSTANCE_NAME \
        --project=$PROJECT_ID \
        --zone=$ZONE \
        --machine-type=$MACHINE_TYPE \
        --network=$NETWORK \
        --subnet=$SUBNET \
        --maintenance-policy=MIGRATE \
        --image-family=$IMAGE_FAMILY \
        --image-project=$IMAGE_PROJECT \
        --boot-disk-size=${DISK_SIZE}GB \
        --boot-disk-type=pd-standard \
        --boot-disk-device-name=${INSTANCE_NAME}-disk \
        $PREEMPTIBLE_FLAG

    echo "Instance $INSTANCE_NAME created successfully."

    # Add SSH key to instance metadata
    echo "Adding SSH key to instance metadata for $INSTANCE_NAME..."
    gcloud compute instances add-metadata $INSTANCE_NAME \
        --zone=$ZONE \
        --metadata=ssh-keys="$(whoami):$(cat $SSH_KEY_PATH)"
}

# Function to set up Filecoin on the instance
setup_filecoin_node() {
    local INSTANCE_NAME=$1
    local IS_MINER=$2

    echo "Setting up Filecoin node on $INSTANCE_NAME (Miner: $IS_MINER)..."

    # Wait for the instance to initialize
    echo "Waiting for the instance $INSTANCE_NAME to be ready..."
    sleep 120  # Wait for 2 minutes for initialization

    # Copy the setup script to the instance
    gcloud compute scp setup_filecoin.sh $INSTANCE_NAME:~ --zone=$ZONE --project=$PROJECT_ID

    # Run the setup script on the instance
    gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID --command="bash ~/setup_filecoin.sh $IS_MINER"

    echo "Filecoin setup complete on $INSTANCE_NAME."
}

# Create or reset the Filecoin miner node
create_or_reset_instance $MINER_INSTANCE_NAME $MACHINE_TYPE_MINER $DISK_SIZE_MINER

# Create or reset the Filecoin client node
create_or_reset_instance $CLIENT_INSTANCE_NAME $MACHINE_TYPE_CLIENT $DISK_SIZE_CLIENT

# Filecoin setup script
cat <<'EOF' > setup_filecoin.sh
#!/bin/bash

# Exit on any error
set -e

# Arguments
IS_MINER=$1

# Variables
LOTUS_REPO="https://github.com/filecoin-project/lotus.git"
LOTUS_DIR="$HOME/lotus-devnet"
GO_VERSION="1.17.5"
SECTOR_SIZE="34359738368"  # 32 GiB in bytes
NUM_SECTORS=1

# Update and install dependencies
echo "Updating and installing dependencies..."
sudo apt update
sudo apt install -y build-essential jq pkg-config curl git bzr hwloc

# Install Go
echo "Installing Go..."
wget https://golang.org/dl/go$GO_VERSION.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go$GO_VERSION.linux-amd64.tar.gz
rm go$GO_VERSION.linux-amd64.tar.gz

# Set Go environment variables
echo "Setting Go environment variables..."
echo "export PATH=\$PATH:/usr/local/go/bin" >> ~/.bashrc
echo "export GOPATH=\$HOME/go" >> ~/.bashrc
echo "export PATH=\$PATH:\$GOPATH/bin" >> ~/.bashrc
source ~/.bashrc

# Verify Go installation
echo "Verifying Go installation..."
if ! command -v go &> /dev/null; then
    echo "Go installation failed or PATH not set correctly. Exiting."
    exit 1
fi
echo "Go is installed: $(go version)"

# Install Rust
echo "Installing Rust..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# Ensure the environment is updated
echo "Sourcing .bashrc and Rust environment..."
. "$HOME/.cargo/env"
source ~/.bashrc

# Verify Rust installation
echo "Verifying Rust installation..."
if ! command -v rustc &> /dev/null; then
    echo "Rust installation failed or PATH not set correctly. Exiting."
    exit 1
fi
echo "Rust is installed: $(rustc --version)"

# Clone Lotus repository
echo "Cloning Lotus repository..."
mkdir -p $LOTUS_DIR
cd $LOTUS_DIR
git clone $LOTUS_REPO
cd lotus
git checkout releases

# Build Lotus
echo "Building Lotus binaries..."
make clean all

# Fetch proving parameters
echo "Fetching proving parameters..."
./lotus fetch-params $SECTOR_SIZE

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
    echo "export LOTUS_PATH=$HOME/.lotus-local-net" >> ~/.bashrc
    echo "export LOTUS_MINER_PATH=$HOME/.lotus-miner-local-net" >> ~/.bashrc
    echo "export LOTUS_SKIP_GENESIS_CHECK=_yes_" >> ~/.bashrc
    echo "export CGO_CFLAGS_ALLOW=\"-D__BLST_PORTABLE__\"" >> ~/.bashrc
    echo "export CGO_CFLAGS=\"-D__BLST_PORTABLE__\"" >> ~/.bashrc
    source ~/.bashrc

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
    echo "export LOTUS_PATH=$HOME/.lotus-local-net" >> ~/.bashrc
    source ~/.bashrc

    # Start the client node
    echo "Starting the client node..."
    screen -dmS lotus_client bash -c "cd $LOTUS_DIR/lotus && ./lotus daemon --bootstrap=false"

    echo "Client node setup complete. The client node is running."
fi
EOF

# Set up the miner node
setup_filecoin_node $MINER_INSTANCE_NAME true

# Set up the client node
setup_filecoin_node $CLIENT_INSTANCE_NAME false

echo "All nodes are set up successfully."

