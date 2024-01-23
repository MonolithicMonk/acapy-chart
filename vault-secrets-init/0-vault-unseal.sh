#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# Script to unseal vault using the HTTP API

echo "Starting Vault Unseal Process..."

# Project root directory
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Vault secrets file
secrets_file="${project_root_dir}/vault-secrets-init/0-vault-init.txt"

# Extract configuration values using yq
vault_server_url=$(yq e '.vault.vault_server_url' "${project_root_dir}/override.yaml")

# Check if Vault is already unsealed
vault_status=$(curl -s -k "$vault_server_url/v1/sys/seal-status")
if [[ $(echo $vault_status | jq -r '.sealed') == "false" ]]; then
    echo "Vault is already unsealed."
    exit 0
fi

# Check if Vault is initialized
if [[ $(echo $vault_status | jq -r '.initialized') == "false" ]]; then
    echo "Vault is not initialized."
    exit 1
fi

# Ask the user for the number of shares required to unseal Vault
read -p "Enter the number of shares required to unseal Vault: " required_shares

# Retrieve the specified number of unseal keys from the file
unseal_keys=$(grep "unseal_key" $secrets_file | shuf -n $required_shares | awk '{print $NF}')

# Loop over the keys and unseal the vault
for unseal_key in $unseal_keys; do
    # Use GPG to decrypt the unseal key
    decrypted_unseal_key=$(echo "$unseal_key" | xxd -r -p | gpg -d)

    # Unseal Vault with the decrypted key
    unseal_response=$(curl -s -k --request POST --data '{"key": "'$decrypted_unseal_key'"}' "$vault_server_url/v1/sys/unseal")
    if [[ $(echo $unseal_response | jq -r '.sealed') == "false" ]]; then
        echo "Vault is unsealed."
        exit 0
    fi
done

echo "Vault unseal process complete."
