## Configuring a Key/Value Secret in HashiCorp Vault for BPA
[See Here For Detailed Guide](https://developer.hashicorp.com/vault/tutorials/secrets-management/versioned-kv#step-4-specify-the-number-of-versions-to-keep)

### **Profile**
- Tenant:
  - bpa_tenant_id: {{ .Values.bpa.tenantId }}
- Acapy:
  - acapy_tenant_seed: {{ .Values.bpa.acapy.tenantSeed }}
  - acapy_wallet_key: {{ .Values.bpa.acapy.walletKey }}
  - acapy_tenant_bearer_token: {{ .Values.bpa.acapy.bearerToken }}
- BPA:
  - bpa_bootstrap_password: {{ .Values.bpa.config.bootstrap.password }}
  - bpa_private_key_pem: {{ .Values.bpa.keys.privateKey }}
- Password Policy:
  - password_policy_acapy_tenant_seed: ../policies/password-policy-acapy-tenant-seed.hcl
  - password_policy_acapy_wallet_key: ../policies/password-policy-acapy-wallet-key.hcl
- Server URL:
  - vault_server_url: `https://10.43.141.227`
- Auth Token
  - vault_auth_token: {{ .Values.vault.vault_auth_token }}

### 1. Enable the k/v Secret Engine
[Vault KV Reference](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2)
- Enable the k/v secret engine at the specified path (eg `path=secret/bpa`):
  - **Specify the Engine Version:** Determine whether to use Key/Value (k/v) version 1 or 2, as they offer different features like versioning and soft deletion.
  - **Choose the Mount Path:** Decide on a unique path where the secret engine will be mounted. This path is used in all requests to read and write secrets to this engine.
  - **Configure Engine Options:** Set engine-specific options such as default lease TTL (Time To Live), max TTL, and whether to enable versioning (for k/v v2).

  ```bash
  vault secrets enable -path=secret/bpa -version=2 kv
  ```

### 2. Add Custom Metadata (OPTIONAL)
[Vault KV Metatadata Reference](https://developer.hashicorp.com/vault/docs/commands/kv/metadata)
- Add custom metadata to your configuration:
  - **Define Metadata Fields:** Choose metadata fields such as environment, owner, region, etc., for better organization.
  - **Implement Metadata in Secrets:** Include these fields when writing secrets. Note that metadata is exclusive to k/v version 2.
  - **Utilize Metadata for Management and Auditing:** Use metadata fields for configuration, easier secret management and auditing.

  ```bash
  # Example of adding custom metadata in k/v version 2
  # Use as BPA config template
  vault kv metadata put -mount="secret/bpa" \
    -max-versions=30 -delete-version-after="768h" \
    -custom-metadata=Region="US South Central" \
    -custom-metadata=Component="Acapy" \
    -custom-metadata=Component="BPA" \
    bpa_tenant_id
  ```

### 3. Add Password Policy for Wallet Seed and Tenant Seed
- Securely generate keys for acapy_tenant_seed and acapy_wallet_key
  - **Generate Secure Keys using Policies:** Use the password generation functionalities of vault to generate consistently secure keys without having to copy and paste it from bash scripts

  ```bash
  # Tenant seed policy
  vault write sys/policies/password/acapy_tenant_seed policy="password_policy_acapy_tenant_seed"

  # Walley key policy
  vault write sys/policies/password/acapy_wallet_key policy="password_policy_acapy_wallet_key"
  ```

### 4. Add Data to the Secret Engine
[Vault KV Put Reference](https://developer.hashicorp.com/vault/docs/commands/kv/put)
- Securely store your secrets at the specified path:
  - **Write Secrets to the Engine:** Use vault kv put to add key-value pairs, ensuring that actual secret values are securely handled.

  ```bash
  vault kv put -mount="secret/bpa" bpa_tenant_id \
    acapy_tenant_seed=$(vault read -field password sys/policies/password/acapy_tenant_seed/generate) \
    acapy_wallet_key=$(vault read -field password sys/policies/password/acapy_wallet_key/generate) \
    acapy_tenant_bearer_token="acapy_tenant_bearer_token" \
    bpa_bootstrap_password=$(vault read -field password sys/policies/password/postgresql/generate) \
    bpa_private_key_pem="bpa_private_key_pem"
  ```

### 5.  Verify the secret can be retrieved:
[Vault KV Get Reference](https://developer.hashicorp.com/vault/docs/commands/kv/get)
- Ensure the stored secrets are accessible:

  ```bash
  vault kv get -mount="secret/bpa" bpa_tenant_id
  ```

### 6. Updating the Secret
[Vault KV Put Reference](https://developer.hashicorp.com/vault/docs/commands/kv/put)
- Maintain the integrity of your secrets with updates:
  - **Update Entire Secret:** When updating, provide all key-value pairs to ensure data consistency.
  - **ACL Policy Requirements:** Ensure entities have the update capability in their ACL policy for updating secrets.

  ```bash
  vault kv put -mount="secret/bpa" bpa_tenant_id \
    acapy_tenant_seed="acapy_tenant_seed" \
    acapy_wallet_key="acapy_wallet_key" \
    acapy_tenant_bearer_token="acapy_tenant_bearer_token" \
    bpa_bootstrap_password="bpa_bootstrap_password" \
    bpa_private_key_pem="bpa_private_key_pem"
  ```

### 7. Patching the Secret (v2 only)
[Vault KV Patch Reference](https://developer.hashicorp.com/vault/docs/commands/kv/patch)
- Efficiently update specific fields in your secrets:
  - **Selective Field Updates:** Use patching for updating individual fields in a secret, available only in k/v version 2.
  - **ACL Policy for Patching:** Entities must have the patch capability in their ACL policy.
  - **Versioning in k/v v2:** Each patch creates a new version, allowing for a history of changes and rollbacks.

  ```bash
  # Example of patching a secret in k/v version 2
  vault kv put -mount="secret/bpa" bpa_tenant_id \
    acapy_tenant_seed="updated_acapy_tenant_seed_value"

  vault kv put -mount="secret/bpa" bpa_tenant_id \
    bpa_service_name="New Service Name"