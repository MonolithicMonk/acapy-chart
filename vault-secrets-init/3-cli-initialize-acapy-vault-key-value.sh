#!/bin/bash

# Script to create a new vault key/value secret engine profile for a new bpa deployment
# Generates:
# - Tenant ID
# - Acapy tenant seed
# - Acapy wallet key
# - Acapy tenant bearer token
# - BPA bootstrap password
# - BPA private key pem

# - Tenant:
#   - bpa_tenant_id: {{ .Values.bpa.tenantId }}
# - Acapy:
#   - acapy_tenant_bearer_token: {{ .Values.bpa.acapy.bearerToken }}
# - BPA:
#   - bpa_private_key_pem: {{ .Values.bpa.keys.privateKey }}

# Determine the project root directory relative to the script location
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Base64 encode password policy
password_policy_acapy_tenant_seed=$(cat ${project_root_dir}/policies/password-policy-acapy-tenant-seed.hcl | base64 -w 0)
password_policy_acapy_wallet_key=$(cat ${project_root_dir}/policies/password-policy-acapy-wallet-key.hcl | base64 -w 0)

# Define file name for the vault key / value profile
bpa_vault_key_value_profile_file="3-initialize-bpa-vault-key-value.txt"

# Acquire bp_tenant_id from .bpa.tenantId path in ../override.yaml file using yq
bpa_tenant_id=$(yq e '.bpa.tenantId' "${project_root_dir}/override.yaml")

# Acquire acapy_tenant_bearer_token from .bpa.acapy.bearerToken path in ../override.yaml file using yq
acapy_tenant_bearer_token=$(yq e '.bpa.acapy.bearerToken' "${project_root_dir}/override.yaml")

# Generate 4096 RSA private key and base64 encode it
bpa_private_key_pem=$(openssl genpkey -algorithm RSA -outform PEM -pkeyopt rsa_keygen_bits:4096 | base64 -w 0)

# Write a series of Vault configurations to 'bpa_vault_key_value_profile_file',
# outlining the steps for creating a Vault key / value secret engine profile for the new deployment

echo "# Follow these commands to properly setup key / value secret for a new BPA profile" >| $bpa_vault_key_value_profile_file

echo -e "\n# Profile: " >> $bpa_vault_key_value_profile_file
echo "# - bpa_tenant_id: {{ .Values.bpa.tenantId }}" >> $bpa_vault_key_value_profile_file
echo "# - acapy_tenant_bearer_token: {{ .Values.bpa.acapy.bearerToken }}" >> $bpa_vault_key_value_profile_file
echo "# - bpa_private_key_pem: {{ .Values.bpa.keys.privateKey }}" >> $bpa_vault_key_value_profile_file
echo "# Make sure to subsitute with actual values in your values.yaml file" >> $bpa_vault_key_value_profile_file
## Add custom metadata to your configuration
echo -e "\n# ======================" >> $bpa_vault_key_value_profile_file
echo "# 1. Add Custom Metadata" >> $bpa_vault_key_value_profile_file
echo -e "# ======================\n" >> $bpa_vault_key_value_profile_file
echo "vault kv metadata put -mount=\"secret/bpa\" \\" >> $bpa_vault_key_value_profile_file
echo "  -max-versions=30 -delete-version-after=\"768h\" \\" >> $bpa_vault_key_value_profile_file
echo "  -custom-metadata=Region=\"US South\" \\" >> $bpa_vault_key_value_profile_file
echo "  -custom-metadata=Component=\"Acapy\" \\" >> $bpa_vault_key_value_profile_file
echo "  -custom-metadata=Component=\"BPA\" \\" >> $bpa_vault_key_value_profile_file
echo "  $bpa_tenant_id" >> $bpa_vault_key_value_profile_file

## Securely generate keys for acapy_tenant_seed and acapy_wallet_key
echo -e "\n# ======================================================" >> $bpa_vault_key_value_profile_file
echo "# 2. Add Password Policy for Wallet Seed and Tenant Seed" >> $bpa_vault_key_value_profile_file
echo -e "# ======================================================\n" >> $bpa_vault_key_value_profile_file
echo "vault write sys/policies/password/acapy_tenant_seed policy=\"$password_policy_acapy_tenant_seed\"" >> $bpa_vault_key_value_profile_file
echo "" >> $bpa_vault_key_value_profile_file
echo "vault write sys/policies/password/acapy_wallet_key policy=\"$password_policy_acapy_wallet_key\"" >> $bpa_vault_key_value_profile_file

## Securely store your secrets at the specified path
echo -e "\n# ================================" >> $bpa_vault_key_value_profile_file
echo "# 3. Add Data to the Secret Engine" >> $bpa_vault_key_value_profile_file
echo -e "# ================================\n" >> $bpa_vault_key_value_profile_file
echo "vault kv put -mount=\"secret/bpa\" $bpa_tenant_id \\" >> $bpa_vault_key_value_profile_file
echo "  acapy_tenant_seed=\"\$(vault read -field=password sys/policies/password/acapy_tenant_seed/generate)\" \\" >> $bpa_vault_key_value_profile_file
echo "  acapy_wallet_key=\"\$(vault read -field=password sys/policies/password/acapy_wallet_key/generate)\" \\" >> $bpa_vault_key_value_profile_file
echo "  acapy_tenant_bearer_token=\"$acapy_tenant_bearer_token\" \\" >> $bpa_vault_key_value_profile_file
echo "  bpa_bootstrap_password=\"\$(vault read -field=password sys/policies/password/postgresql/generate)\" \\" >> $bpa_vault_key_value_profile_file
echo "  bpa_private_key_pem=\"$bpa_private_key_pem\"" >> $bpa_vault_key_value_profile_file
