#!/bin/bash

# Script to create a new vault key/value secret engine profile to store postgresql admin credentials
# Generates:
# - Username
# - Password

# Determine the project root directory relative to the script location
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Set postgresql_key_name value
postgresql_key_name="postgresql_kv_secret"

# Set postgresql_secret_path value
postgresql_secret_path="secret/postgresql/admin"

# Set region value
region="US South"

# Vault secrets file
secrets_file="${project_root_dir}/vault-secrets-init/0-vault-init.txt"

# Retrieve the root token from the file
encrypted_token=$(grep "root_token" $secrets_file | awk '{print $NF}')

# Decrypt the root token
vault_auth_token=$(echo "$encrypted_token" | base64 --d | gpg -d)

# Extract configuration values using yq
postgresql_admin_username=$(yq e '.vault.postgresql_admin_username' "${project_root_dir}/override.yaml")
postgresql_admin_password=$(yq e '.vault.postgresql_admin_password' "${project_root_dir}/override.yaml")
vault_server_url=$(yq e '.vault.vault_server_url' "${project_root_dir}/override.yaml")

## 1.  Enable the k/v secret engine at the secret/postgresql/admin using the HTTP API
echo "Enabling k/v secret engine at 'secret/postgresql/admin'..."

secret_engine_payload=$(
  cat <<EOF
{
  "type": "kv-v2",
  "config": {
    "force_no_cache": true,
    "audit_non_hmac_request_keys": ["$postgresql_admin_username", "$postgresql_admin_password"],
    "audit_non_hmac_response_keys": ["$postgresql_admin_username", "$postgresql_admin_password"]
  }
}
EOF
)
curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$secret_engine_payload" $vault_server_url/v1/sys/mounts/$postgresql_secret_path

## 2. Add custom metadata to the secret/postgresql/admin path using the HTTP API
echo "Adding custom metadata to the secret/postgresql/admin path..."
metadata_payload=$(
  cat <<EOF
{
  "custom_metadata": {
    "max_versions": 30,
    "delete_version_after": "8760h",
    "Region": "$region",
    "Component": "PostgreSQL",
    "Component": "Sensitive",
    "Component": "Top Secret"
  }
}
EOF
)
curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$metadata_payload" $vault_server_url/v1/$postgresql_secret_path/metadata/$postgresql_key_name

## 3. Securely store your secrets at the secret/postgresql/admin path using the HTTP API
secret_payload=$(
  cat <<EOF
{
  "data": {
    "postgresql_admin_username": "$postgresql_admin_username",
    "postgresql_admin_password": "$postgresql_admin_password"
  }
}
EOF
)
curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$secret_payload" $vault_server_url/v1/$postgresql_secret_path/data/$postgresql_key_name


# Step 4: Verify the metadata can be retrieved
curl -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$postgresql_secret_path/metadata/$postgresql_key_name

# Step 5: Verify the secrets can be retrieved (Subkeys to hide the secret values)
curl -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$postgresql_secret_path/subkeys/$postgresql_key_name

