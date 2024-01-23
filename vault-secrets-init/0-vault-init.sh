#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# Script to initialize vault using the HTTP API

# Function to check response for errors
check_response() {
    if [[ $1 == *"errors"* ]]; then
        echo "Error in response: $1"
        exit 1
    fi
}

# Project root directory
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Output directory (where the vault secrets will be stored)
output_file="${project_root_dir}/vault-secrets-init/0-vault-init.txt"

# Extract configuration values using yq
vault_server_url=$(yq e '.vault.vault_server_url' "${project_root_dir}/override.yaml")

# Check if Vault is already initialized
vault_status=$(curl -s -k "$vault_server_url/v1/sys/init")
if [[ $(echo $vault_status | jq -r '.initialized') == "true" ]]; then
    echo "Vault is already initialized."
    exit 0
fi

# Initialize vault
echo -e "\nInitializing vault...\n"

# Initialization payload parameters
# - secret_shares: number of shares to split the master key into
# - secret_threshold: number of shares required to reconstruct the master key
# - pgp_keys: array of PGP public keys used to encrypt the output unseal keys (found in $project_root_dir/vault-secrets-init/pgpKey.asc)
# - root_token_pgp_key: PGP public key used to encrypt the root token (found in $project_root_dir/vault-secrets-init/pgpKey.asc)

# Base64 encode the PGP public keys
# Note: the -w 0 option is used to prevent base64 from adding line breaks
# Note: the PGP public key must be in binary format (not ASCII armored)
# Use the following command to convert an ASCII armored PGP public key to binary format:
# gpg --dearmor < $project_root_dir/vault-secrets-init/pgpKey.asc > $project_root_dir/vault-secrets-init/pgpKey.bin
# Use the following command to export a PGP public key in binary format and base64 encode it in one line:
# gpg --export <key-id> | base64 -w 0
# Reference: https://www.vaultproject.io/docs/concepts/pgp-gpg-keybase.html
base64_pgp_keys=$(cat $project_root_dir/vault-secrets-init/pgp.key)

# Check if base64_pgp_keys is base64 encoded and or in binary format
if [[ $base64_pgp_keys == *"BEGIN PGP PUBLIC KEY BLOCK"* ]]; then
    echo "Error: PGP public key is not in binary format"
    echo -e "/nUse the following command to list your PGP keys:"
    echo -e "gpg --list-keys\n"
    echo -e "\nUse the following command to export a PGP public key in binary format and base64 encode it in one line:"
    echo "gpg --export <key-id> | base64 -w 0"
    exit 1
fi

# Initialization payload
init_payload=$(
  cat <<EOF
{
  "secret_shares": 5,
  "secret_threshold": 3,
  "pgp_keys": [
    "$base64_pgp_keys",
    "$base64_pgp_keys",
    "$base64_pgp_keys",
    "$base64_pgp_keys",
    "$base64_pgp_keys"
  ],
  "root_token_pgp_key": "$base64_pgp_keys"
}
EOF
)

# Initialize vault and check for errors
init_response=$(curl -s -k --request POST --data "$init_payload" "$vault_server_url/v1/sys/init")
check_response "$init_response"

# Extract the root token and unseal keys from the response
root_token=$(echo "$init_response" | jq -r '.root_token')
unseal_keys=$(echo "$init_response" | jq -r '.keys[]')

# Check if root token and unseal keys are present
if [ -z "$root_token" ] || [ -z "$unseal_keys" ]; then
    echo "Error: Failed to extract root token or unseal keys from response"
    exit 1
fi

# Write the root token and unseal keys to a file
# Note: Prefix the root token with "root_token: "
# Note: Iterate over the unseal keys do the following:
# - output each unseal key on a new line
# - prefix each unseal key with "unseal_key: "
echo -e "\nWriting vault root token and unseal keys to '$output_file'...\n"
echo "root_token: $root_token" >| "$output_file"
for unseal_key in $unseal_keys; do
    echo "unseal_key: $unseal_key" >> "$output_file"
done

# Set the permissions on the file
chmod 600 "$output_file"

echo -e "\nVault initialized successfully.\n"
