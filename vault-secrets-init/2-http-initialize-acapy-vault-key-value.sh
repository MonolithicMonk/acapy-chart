#!/bin/bash

set -e
# Script to configure a Key/Value secret in HashiCorp Vault for a new Acapy deployment
# This script performs the following actions:
# 1. Enable the k/v Secret Engine
# 2. Add custom metadata to the configuration
# 3. Create password policies for acapy_seed and acapy_wallet_key
# 4. Securely store secrets in the Vault
# 5. Retrieve and verify stored secrets

# Determine the project root directory
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Configuration values are sourced from ../override-db.yaml file

# Base64 encode password policies
password_policy_acapy_seed=$(base64 -w 0 < ${project_root_dir}/policies/password-policy-acapy-tenant-seed.hcl)
password_policy_acapy_wallet_key=$(base64 -w 0 < ${project_root_dir}/policies/password-policy-acapy-wallet-key.hcl)

# Extract configuration values using yq
vault_postgres_user_group=$(yq e '.vault.postgresUserGroup' "${project_root_dir}/override-db.yaml")
vault_server_url=$(yq e '.vault.vault_server_url' "${project_root_dir}/override-db.yaml")

# Vault secrets file
secrets_file="${project_root_dir}/vault-secrets-init/0-vault-init.txt"

# Retrieve the root token from the file
encrypted_token=$(grep "root_token" $secrets_file | awk '{print $NF}')

# Decrypt the root token
vault_auth_token=$(echo "$encrypted_token" | base64 --d | gpg -d)

acapy_secret_path="secret/acapy"

acapy_seed_policy="acapy_seed_policy"
acapy_wallet_key_policy="acapy_wallet_key_policy"

# Step 1: Enable k/v secret engine

# Ensure the k/v secret engine is enabled at the specified path

# List all secret engines
list_secret_engines=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" "$vault_server_url/v1/sys/mounts")

# Secret engine configuration 
secret_engine_payload=$(
  cat <<EOF
{
  "type": "kv-v2",
  "description": "Acapy secret engine to store secrets for Acapy",
  "config": {
    "default_lease_ttl": "768h",
    "max_versions": 30,
    "delete_version_after": "768h"
  }
}
EOF
)

# Custom metadata
metadata_payload=$(
  cat <<EOF
{
  "max_versions": 30,
  "delete_version_after": "768h",
  "custom_metadata": {
    "Region": "US South Central",
    "Component": "Acapy"
  }
}
EOF
)

# Check if '$acapy_secret_path' is in the response aka is the k/v secret engine enabled at '$acapy_secret_path'
if echo "$list_secret_engines" | jq --arg acapy_secret_path "$acapy_secret_path" -e '.[$acapy_secret_path+"/"]' > /dev/null; then
    echo "k/v secret engine is already enabled at '$acapy_secret_path'."
else
    # Enable k/v secret engine at '$acapy_secret_path'
    echo "k/v secret engine is not enabled at '$acapy_secret_path'."
    echo "Enabling k/v secret engine at '$acapy_secret_path'..."
    curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$secret_engine_payload" "$vault_server_url/v1/sys/mounts/$acapy_secret_path" | jq
    
    # Add custom metadata to the configuration
    curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$metadata_payload" $vault_server_url/v1/$acapy_secret_path/metadata/$vault_postgres_user_group | jq
    echo "k/v secret engine now enabled at '$acapy_secret_path' and custom metadata added."
fi



# Step 3: Create password policies

# acapy_seed password policy
seed_password_policy_payload=$(cat <<EOF
{
  "policy": "$password_policy_acapy_seed"
}
EOF
)

# Ensure does not exist
# List all password policies
list_password_policies=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" --request LIST "$vault_server_url/v1/sys/policies/password")

# Check if 'acapy_seed' is in the response
if echo "$list_password_policies" | jq -e --arg acapy_seed_policy "$acapy_seed_policy" '.data.keys[] | select(. == $acapy_seed_policy)' > /dev/null; then
    echo "Password policy 'acapy_seed' already exists."
else
    # Create password policy for acapy_seed
    echo "Password policy 'acapy_seed' does not exist."
    echo "Creating password policy 'acapy_seed'..."
    curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$seed_password_policy_payload" $vault_server_url/v1/sys/policies/password/$acapy_seed_policy | jq
    echo "Password policy 'acapy_seed' created."
fi

# acapy_wallet_key password policy
wallet_key_password_policy_payload=$(cat <<EOF
{
  "policy": "$password_policy_acapy_wallet_key"
}
EOF
)

# Ensure acapy_wallet_key password policy does not exist

# Check if 'acapy_wallet_key' is in the policy list
if echo "$list_password_policies" | jq -e --arg acapy_wallet_key_policy "$acapy_wallet_key_policy" '.data.keys[] | select(. == $acapy_wallet_key_policy)' > /dev/null; then
    echo "Password policy 'acapy_wallet_key' already exists."
else
    # Create password policy for acapy_wallet_key
    echo "Password policy 'acapy_wallet_key' does not exist."
    echo "Creating password policy 'acapy_wallet_key'..."
    curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$wallet_key_password_policy_payload" $vault_server_url/v1/sys/policies/password/$acapy_wallet_key_policy | jq
    echo "Password policy 'acapy_wallet_key' created."
fi

# Generate acapy_seed, acapy_wallet_key, and acapy_multitenant_jwt_secret using the password policies
acapy_seed=$(curl -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/sys/policies/password/acapy_seed/generate | jq -r '.data.password')
acapy_wallet_key=$(curl -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/sys/policies/password/acapy_wallet_key/generate | jq -r '.data.password')
acapy_multitenant_jwt_secret=$(curl -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/sys/policies/password/acapy_wallet_key/generate | jq -r '.data.password')

# Step 4: Securely store secrets
echo -e "\nStoring secrets in Vault...\n"
payload=$(
  cat <<EOF
{
  "data": {
    "acapy_seed": "$acapy_seed",
    "acapy_wallet_key": "$acapy_wallet_key",
    "acapy_multitenant_jwt_secret": "$acapy_multitenant_jwt_secret"
  }
}
EOF
)
curl -s -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$payload" $vault_server_url/v1/$acapy_secret_path/data/$vault_postgres_user_group | jq

# Step 5: Verify the metadata can be retrieved
curl -s -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$acapy_secret_path/metadata/$vault_postgres_user_group | jq

# Step 6: Verify the secret can be retrieved (Subkeys to hide the secret values)
echo -e "\nVerifying the stored secrets...\n"
curl -s -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$acapy_secret_path/subkeys/$vault_postgres_user_group | jq

echo -e "\nVault configuration for Acapy deployment completed."

# CSI DRIVER OPERATIONS
# We're going to grant service accounts access to the secrets in Vault using policies
# Policies grant grant access by specifying a path and capabilities and which service accounts can access the secrets at that path

# CSI Access for $acapy_secret_path 

echo -e "\nConfiguring Vault CSI driver for Kubernetes and Vault...\n"
# 1. Ensure kubernetes auth method is enabled

# List all auth methods
list_auth_methods=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" "$vault_server_url/v1/sys/auth")

# Retrieve the Kubernetes host from the Kubernetes cluster
KUBERNETES_PORT_443_TCP_ADDR=$(kubectl get service kubernetes -o jsonpath='{.spec.clusterIP}')

# Retrieve the Kubernetes service port from the Kubernetes cluster
KUBERNETES_PORT_443_TCP_PORT=$(kubectl get service kubernetes -o jsonpath='{.spec.ports[?(@.name=="https")].port}')

# Kubernetes auth configuration payload
kubernetes_auth_payload=$(
  cat <<EOF
{
  "type": "kubernetes",
  "description": "Kubernetes auth method to authenticate with Vault using a Kubernetes Service Account",
  "config": {
    "default_lease_ttl": "768h"
  }
}
EOF
)

# Kubernetes auth configuration payload
kubernetes_auth_config_payload=$(
  cat <<EOF
{
  "kubernetes_host": "https://$KUBERNETES_PORT_443_TCP_ADDR:$KUBERNETES_PORT_443_TCP_PORT"
}
EOF
)

# Check if 'kubernetes/' is in the response aka enabled already
if echo "$list_auth_methods" | jq -e '.["kubernetes/"]' > /dev/null; then
    echo "Kubernetes auth method is already enabled."
else
    # Enable kubernetes auth method (include data in curl request)
    echo "Kubernetes auth method is not enabled."
    echo "Enabling kubernetes auth method..."
    curl -s -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$kubernetes_auth_payload" "$vault_server_url/v1/sys/auth/kubernetes" | jq
    
    # Ensure kubernetes auth method is configured
    echo -e "\nConfiguring kubernetes auth method with the Kubernetes host...\n"

    # Configure the auth method with the Kubernetes host
    curl -s -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$kubernetes_auth_config_payload" "$vault_server_url/v1/auth/kubernetes/config" | jq
    echo "Kubernetes auth method now enabled and configured."
fi

# 2. Create a policy for the kubernetes service account to read the secrets at the specified path

# Policy name
# Service account policy named is derived from the following:
# - the read path (eg $acapy_secret_path/data/$vault_postgres_user_group)
# - replace '/' with '_'
# - append '_service_account_policy'
path_to_secret=$acapy_secret_path/data/$vault_postgres_user_group
service_account_policy_name=$(echo $path_to_secret | sed 's/\//_/g')_service_account_policy

echo -e "\nCreating a policy for the kubernetes service account to read the secrets at...\n"
echo -e "... $service_account_policy_name\n"

# Kubernetes service account policy payload
acapy_auth_policy_payload=$(
  cat <<EOF
{
  "policy": "path \"$acapy_secret_path/data/$vault_postgres_user_group\" {capabilities = [\"read\"]}"
}
EOF
)
curl -s -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$acapy_auth_policy_payload" $vault_server_url/v1/sys/policies/acl/$service_account_policy_name | jq

# 3. Create a role that maps a Kubernetes Service Account to the policy:

vault_service_account_name=$vault_postgres_user_group

# role name
# Service account role name is derived from the following:
# - the read path (eg $acapy_secret_path/data/$vault_postgres_user_group)
# - replace '/' with '_'
# - append '_service_account_role'
path_to_secret=$acapy_secret_path/data/$vault_postgres_user_group
service_account_role_name=$(echo $path_to_secret | sed 's/\//_/g')_service_account_role

echo -e "\nCreating a role that maps a Kubernetes Service Account to the policy...\n"
echo -e "... $service_account_role_name\n"

# Kubernetes service account role payload
acapy_auth_role_payload=$(
  cat <<EOF
{
  "bound_service_account_names": "$vault_service_account_name",
  "bound_service_account_namespaces": "default",
  "policies": ["$service_account_policy_name"],
  "ttl": "768h"
}
EOF
)
curl -s -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$acapy_auth_role_payload" $vault_server_url/v1/auth/kubernetes/role/$service_account_role_name | jq


# CSI Access for $shared_services_secret_path/data/$shared_services_key_name
shared_services_secret_path=secret/shared_services
shared_services_key_name=shared_services_kv_secret

# Create a policy for the kubernetes service account to read the secrets at the specified path
# path: $shared_services_secret_path/data/$shared_services_key_name

# Policy name
# Service account policy named is derived from the following:
# - the read path (eg $shared_services_secret_path)
# - replace '/' with '_'
# - append $vault_postgres_user_group
# - append '_service_account_policy'
shared_service_account_policy_name=$(echo $shared_services_secret_path | sed 's/\//_/g')_${vault_postgres_user_group}_service_account_policy

echo -e "\nCreating a policy for the kubernetes service account to read the secrets at...\n"
echo -e "... $shared_service_account_policy_name\n"

# Kubernetes service account policy payload
shared_services_auth_policy_payload=$(
  cat <<EOF
{
  "policy": "path \"$shared_services_secret_path/data/$shared_services_key_name\" {capabilities = [\"read\"]}"
}
EOF
)
curl -s -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$shared_services_auth_policy_payload" $vault_server_url/v1/sys/policies/acl/$shared_service_account_policy_name | jq

# Create a role that maps a Kubernetes Service Account to the policy:

# role name
# Service account role name is derived from the following:
# - the read path (eg $shared_services_secret_path)
# - replace '/' with '_'
# - append $vault_postgres_user_group
# - append '_service_account_role'
shared_service_account_role_name=$(echo $shared_services_secret_path | sed 's/\//_/g')_${vault_postgres_user_group}_service_account_role

echo -e "\nCreating a role that maps a Kubernetes Service Account to the policy...\n"
echo -e "... $shared_service_account_role_name\n"

# Kubernetes service account role payload
shared_services_auth_role_payload=$(
  cat <<EOF
{
  "bound_service_account_names": "$vault_service_account_name",
  "bound_service_account_namespaces": "default",
  "policies": ["$shared_service_account_policy_name"],
  "ttl": "768h"
}
EOF
)
curl -s -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$shared_services_auth_role_payload" $vault_server_url/v1/auth/kubernetes/role/$shared_service_account_role_name | jq

echo -e "\nVault CSI driver configuration completed.\n"


echo -e "\n# ========== CRITICAL UPDATE REQUIRED =========="

echo -e "\n# =========================================================================================="
echo "Updating your override-db.yaml file with the following:"
echo -e " - vault.kubernetes_authentication_role_names.acapy: $service_account_role_name"
echo -e " - vault.kubernetes_authentication_role_names.sharedServices: $shared_service_account_role_name"
echo -e "# ==============================================================================================\n"

yq e -i '.vault.kubernetes_authentication_role_names.acapy = "'$service_account_role_name'"' "${project_root_dir}/override-db.yaml"
yq e -i '.vault.kubernetes_authentication_role_names.sharedServices = "'$shared_service_account_role_name'"' "${project_root_dir}/override-db.yaml"

echo -e "\n Operation completed...\n"