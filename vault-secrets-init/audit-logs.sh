#!/bin/bash

# Script to log Vault audit logs to stdout

# Determine the project root directory
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Acquire vault_server_url from .vault.vault_server_url path in ../override.yaml file using yq
vault_server_url=$(yq e '.vault.vault_server_url' "${project_root_dir}/override.yaml")


# Vault secrets file
secrets_file="${project_root_dir}/vault-secrets-init/0-vault-init.txt"

# Retrieve the root token from the file
encrypted_token=$(grep "root_token" $secrets_file | awk '{print $NF}')

# Decrypt the root token
vault_auth_token=$(echo "$encrypted_token" | base64 --d | gpg -d)


# Configure vault audit log to file at stdout
# The purpose of this is be able to view the audit log in the container logs
curl -k --header "X-Vault-Token: $vault_auth_token" \
    --request PUT \
    --data '{"type": "file", "options": {"file_path": "stdout"}}' \
    "$vault_server_url/v1/sys/audit/stdout"
