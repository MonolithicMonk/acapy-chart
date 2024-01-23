#!/bin/bash

# Script to create a new vault key/value secret engine profile for third party secrets
# Generates:
# - Oauth client secret
# - MailJet API key
# - MailJet API secret


# Set third_party_key_name value
third_party_key_name="third_party_kv_secret"

# Determine the project root directory relative to the script location
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Extract configuration values using yq
oauth_client_secret=$(yq e '.authprovider.clientSecret' "${project_root_dir}/override.yaml")
mail_jet_api_key=$(yq e '.bpa.config.mail.apiKey' "${project_root_dir}/override.yaml")
mail_jet_api_secret=$(yq e '.bpa.config.mail.apiSecret' "${project_root_dir}/override.yaml")

# Vault secrets file
secrets_file="${project_root_dir}/vault-secrets-init/0-vault-init.txt"

# Retrieve the root token from the file
encrypted_token=$(grep "root_token" $secrets_file | awk '{print $NF}')

# Decrypt the root token
vault_auth_token=$(echo "$encrypted_token" | base64 --d | gpg -d)

vault_server_url=$(yq e '.vault.vault_server_url' "${project_root_dir}/override.yaml")

external_secret_path=secret/external

## 1. Enable the k/v secret engine at the specified path (eg `path=$external_secret_path`) using the HTTP API

# Ensure the k/v secret engine is enabled at the specified path

# List all secret engines
list_secret_engines=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" "$vault_server_url/v1/sys/mounts")

# Secret engine configuration payload
secret_engine_payload=$(
  cat <<EOF
{
  "type": "kv-v2",
  "description": "BPA third party secrets",
  "config": {
    "default_lease_ttl": "768h",
    "max_versions": 300,
    "delete_version_after": "768h"
  }
}
EOF
)

# Check if '$external_secret_path' is in the response aka is the k/v secret engine enabled at '$external_secret_path'
if echo "$list_secret_engines" | jq --arg external_secret_path "$external_secret_path" -e '.[$external_secret_path+"/"]' > /dev/null; then
    echo "k/v secret engine is already enabled at '$external_secret_path'."
else
    # Enable k/v secret engine at '$external_secret_path'
    echo "k/v secret engine is not enabled at '$external_secret_path'."
    echo "Enabling k/v secret engine at '$external_secret_path'..."
    curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$secret_engine_payload" "$vault_server_url/v1/sys/mounts/$external_secret_path"
    echo "k/v secret engine now enabled at '$external_secret_path'."
fi

## 2. Add custom metadata to $external_secret_path path using the HTTP API
metadata_payload=$(
  cat <<EOF
{
  "max_versions": 30,
  "delete_version_after": "768h",
  "custom_metadata": {
    "Region": "US South",
    "Component": "MailJet",
    "Component": "Oauth",
    "Component": "Third Party"
  }
}
EOF
)
curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$metadata_payload" $vault_server_url/v1/$external_secret_path/metadata/$third_party_key_name

## 3. Securely store your secrets at the specified path using the HTTP API
echo -e "\nSecurely storing your secrets at the specified path using the HTTP API...\n"
secret_payload=$(
  cat <<EOF
{
  "data": {
    "oauth_client_secret": "$oauth_client_secret",
    "mail_jet_api_key": "$mail_jet_api_key",
    "mail_jet_api_secret": "$mail_jet_api_secret"
  }
}
EOF
)
curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$secret_payload" $vault_server_url/v1/$external_secret_path/data/$third_party_key_name

# Step 4: Verify the metadata can be retrieved
echo -e "\nVerify the metadata can be retrieved...\n"
curl -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$external_secret_path/metadata/$third_party_key_name

# Step 5: Verify the secrets can be retrieved (Subkeys to hide the secret values)
echo -e "\nVerify the secrets can be retrieved (Subkeys to hide the secret values)...\n"
curl -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$external_secret_path/subkeys/$third_party_key_name

