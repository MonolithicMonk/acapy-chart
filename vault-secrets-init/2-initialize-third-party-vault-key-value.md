## Configuring a Key/Value Secret in HashiCorp Vault for BPA
[See Here For Detailed Guide](https://developer.hashicorp.com/vault/tutorials/secrets-management/versioned-kv#step-4-specify-the-number-of-versions-to-keep)

### **Profile**
- Third Party:
  - third_party_key_name: `third_party_kv_secret`
  - Authprovider
    - oauth_client_secret: {{ .Values.authprovider.clientSecret }}
  - MailJet
    - mail_jet_api_key: {{ .Values.bpa.config.mail.apiKey }}
    - mail_jet_api_secret: {{ .Values.bpa.config.mail.apiSecret }}

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
    -custom-metadata=Region="US South" \
    -custom-metadata=Component="MailJet" \
    -custom-metadata=Component="Oauth" \
    -custom-metadata=Component="Third Party" \
    third_party_key_name
  ```

### 3. Add Data to the Secret Engine
[Vault KV Put Reference](https://developer.hashicorp.com/vault/docs/commands/kv/put)
- Securely store your secrets at the specified path:
  - **Write Secrets to the Engine:** Use vault kv put to add key-value pairs, ensuring that actual secret values are securely handled.

  ```bash
  vault kv put -mount="secret/bpa" third_party_key_name \
    oauth_client_secret="oauth_client_secret" \
    mail_jet_api_key="mail_jet_api_key" \
    mail_jet_api_secret="mail_jet_api_secret"
  ```

### 4.  Verify the secret can be retrieved:
[Vault KV Get Reference](https://developer.hashicorp.com/vault/docs/commands/kv/get)
- Ensure the stored secrets are accessible:

  ```bash
  vault kv get -mount="secret/bpa" third_party_key_name
  ```

### 5. Updating the Secret
[Vault KV Put Reference](https://developer.hashicorp.com/vault/docs/commands/kv/put)
- Maintain the integrity of your secrets with updates:
  - **Update Entire Secret:** When updating, provide all key-value pairs to ensure data consistency.
  - **ACL Policy Requirements:** Ensure entities have the update capability in their ACL policy for updating secrets.

  ```bash
  vault kv put -mount="secret/bpa" third_party_key_name \
    oauth_client_secret="oauth_client_secret" \
    mail_jet_api_key="mail_jet_api_key" \
    mail_jet_api_secret="mail_jet_api_secret"
  ```

### 6. Patching the Secret (v2 only)
[Vault KV Patch Reference](https://developer.hashicorp.com/vault/docs/commands/kv/patch)
- Efficiently update specific fields in your secrets:
  - **Selective Field Updates:** Use patching for updating individual fields in a secret, available only in k/v version 2.
  - **ACL Policy for Patching:** Entities must have the patch capability in their ACL policy.
  - **Versioning in k/v v2:** Each patch creates a new version, allowing for a history of changes and rollbacks.

  ```bash
  # Example of patching a secret in k/v version 2
  vault kv put -mount="secret/bpa" third_party_key_name \
    oauth_client_secret="updated_oauth_client_secret_value"

  vault kv put -mount="secret/bpa" third_party_key_name \
    another_third_party_secret="another_third_party_secret_value"