#!/bin/bash

# Script to create a new vault key/value secret engine profile for third party secrets
# Generates:
# - Oauth client secret
# - MailJet API key
# - MailJet API secret

# Define file name for the vault key / value profile
third_party_vault_key_value_profile_file="2-initialize-third-party-vault-key-value.txt"

# Set third_party_key_name value
third_party_key_name="third_party_kv_secret"

# Determine the project root directory relative to the script location
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Acquire oauth_client_secret from .authprovider.clientSecret path in ../override.yaml file using yq
oauth_client_secret=$(yq e '.authprovider.clientSecret' "${project_root_dir}/override.yaml")

# Acquire mail_jet_api_key and mail_jet_api_secret from ../override.yaml file using yq
mail_jet_api_key=$(yq e '.bpa.config.mail.apiKey' "${project_root_dir}/override.yaml")
mail_jet_api_secret=$(yq e '.bpa.config.mail.apiSecret' "${project_root_dir}/override.yaml")

bpa_secret_path=secret/bpa

# Write a series of Vault configurations to 'third_party_vault_key_value_profile_file',
# outlining the steps for creating a Vault key / value secret engine profile for the new deployment

echo "# Follow these commands to properly setup key / value secret for a new third party kv profile" >| $third_party_vault_key_value_profile_file

echo -e "\n# Profile: " >> $third_party_vault_key_value_profile_file
echo "# - third_party_kv_secret: {{ .Values.vault.third_party_kv_secret }}" >> $third_party_vault_key_value_profile_file
echo "# - oauth_client_secret: {{ .Values.authprovider.clientSecret }}" >> $third_party_vault_key_value_profile_file
echo "# - mail_jet_api_key: {{ .Values.bpa.config.mail.apiKey }}" >> $third_party_vault_key_value_profile_file
echo "# - mail_jet_api_secret: {{ .Values.bpa.config.mail.apiSecret }}" >> $third_party_vault_key_value_profile_file
echo "# Make sure to subsitute with actual values in your values.yaml file" >> $third_party_vault_key_value_profile_file


## Enable the k/v secret engine at the specified path (eg `path=$bpa_secret_path`)
echo -e "\n# ==========================================================" >> $third_party_vault_key_value_profile_file
echo "# 1. Enable the k/v Secret Engine (v2) (If not done already)" >> $third_party_vault_key_value_profile_file
echo -e "# ==========================================================\n" >> $third_party_vault_key_value_profile_file
echo "vault secrets enable -path=\"$bpa_secret_path\" -default-lease-ttl=\"768h\" -max-lease-ttl=\"768h\" -description=\"BPA third party secrets\" -version=2 kv" >> $third_party_vault_key_value_profile_file

## Add custom metadata to your configuration
echo -e "\n# ======================" >> $third_party_vault_key_value_profile_file
echo "# 2. Add Custom Metadata" >> $third_party_vault_key_value_profile_file
echo -e "# ======================\n" >> $third_party_vault_key_value_profile_file
echo "vault kv metadata put -mount=\"$bpa_secret_path\" \\" >> $third_party_vault_key_value_profile_file
echo "  -max-versions=30 -delete-version-after=\"768h\" \\" >> $third_party_vault_key_value_profile_file
echo "  -custom-metadata=Component=\"MailJet\" \\" >> $third_party_vault_key_value_profile_file
echo "  -custom-metadata=Component=\"Oauth\" \\" >> $third_party_vault_key_value_profile_file
echo "  -custom-metadata=Component=\"Third Party\" \\" >> $third_party_vault_key_value_profile_file
echo "  $third_party_key_name" >> $third_party_vault_key_value_profile_file

## Securely store your secrets at the specified path
echo -e "\n# ==============================================" >> $third_party_vault_key_value_profile_file
echo "# 3. Add Data to the Secret Engine" >> $third_party_vault_key_value_profile_file
echo -e "# ==============================================\n" >> $third_party_vault_key_value_profile_file
echo "vault kv put -mount=\"$bpa_secret_path\" $third_party_key_name \\" >> $third_party_vault_key_value_profile_file
echo "  oauth_client_secret=\"$oauth_client_secret\" \\" >> $third_party_vault_key_value_profile_file
echo "  mail_jet_api_key=\"$mail_jet_api_key\" \\" >> $third_party_vault_key_value_profile_file
echo "  mail_jet_api_secret=\"$mail_jet_api_secret\"" >> $third_party_vault_key_value_profile_file

echo -e "\n View Results in ./$third_party_vault_key_value_profile_file"