## PostgreSQL User and Vault Configuration Guide

### ***Profile***
- Root:
  - vault_postgres_user_group: {{ . Values.vault.postgresUserGroup }}
- Database:
  - db_name: {{ .Values.db.database }}
  - db_host: {{ .Values.db.host }}
  - db_port: {{ .Values.db.port }}
  - vault_postgres_root_user: Generated
  - vault_postgres_password: Generated
- Password Policy:
  - vault_password_policy: ../policies/password-policy.hcl

### 1. Create a PostgreSQL "Group"
- Create a group for managing access to dynamically generated credentials:
  - This group will be used to manage access to dynamically generated credentials.
  - Ensure the group has adequate permissions for these tasks.
  ```sql
  CREATE DATABASE $db_name;
  REVOKE ALL ON DATABASE $db_name FROM PUBLIC;
  REVOKE ALL ON DATABASE $db_name FROM PUBLIC;
  CREATE ROLE $vault_postgres_user_group;
  GRANT CONNECT ON DATABASE $db_name TO $vault_postgres_user_group;
  GRANT ALL PRIVILEGES ON SCHEMA public TO $vault_postgres_user_group;
  GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $vault_postgres_user_group;
  GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $vault_postgres_user_group;
  GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO $vault_postgres_user_group;
  ALTER DATABASE $db_name OWNER TO $vault_postgres_user_group;
  ```

### 2. Creating a PostgreSQL User
- Create a user for Vault with Necessary Permissions:
  - This user will manage other database users and roles through Vault.
  - Ensure the user has adequate permissions for these tasks.

  ```sql
  CREATE USER $vault_postgres_root_user WITH ENCRYPTED PASSWORD '$vault_postgres_password' CREATEROLE;
  ```

### 3.  Add PostgreSQL User to Group
- Add the user to the previously created group
  - So that user will inherit the group's permissions
  - **Simplified Permission Management:** Manage permissions at the group level.
  - **Consistency and Security:** Uniform permissions across similar users.
  ```sql
  GRANT $vault_postgres_user_group TO $vault_postgres_root_user;
  ```

### 4. Create a Trigger to set Ownership of Created Objects
- Trigger to address ownership issues that may arise when using a temporary (dynamic) role to alter the schema.
  - Will mitigate against race conditions.
  - Will be triggered on table, function, schema, and sequence creation.
  ```sql
  CREATE OR REPLACE FUNCTION trg_create_set_owner()
    RETURNS event_trigger
    LANGUAGE plpgsql
  AS $$
  DECLARE
    obj record;
  BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
      IF obj.schema_name IN ('public') THEN
        IF obj.command_tag IN ('CREATE TABLE', 'CREATE FUNCTION', 'CREATE SCHEMA') THEN
          EXECUTE format('ALTER %s %s OWNER TO $vault_postgres_user_group', substring(obj.command_tag from 8), obj.object_identity);
        ELSIF obj.command_tag = 'CREATE SEQUENCE' AND NOT EXISTS(SELECT s.relname FROM pg_class s JOIN pg_depend d ON d.objid = s.oid WHERE s.relkind = 'S' AND d.deptype='a' and s.relname = split_part(obj.object_identity, '.', 2)) THEN
          EXECUTE format('ALTER SEQUENCE %s OWNER TO $vault_postgres_user_group', obj.object_identity);
        END IF;
      END IF;
    END LOOP;
  END;
  $$;

  CREATE EVENT TRIGGER trg_create_set_owner
   ON ddl_command_end
   WHEN tag IN ('CREATE TABLE', 'CREATE FUNCTION', 'CREATE SCHEMA', 'CREATE SEQUENCE')
   EXECUTE PROCEDURE trg_create_set_owner();
  ```

### 5.  Setup Password Policy and Database Secrets Engine
[More information on Vault password policies](https://developer.hashicorp.com/vault/docs/concepts/password-policies)

- Create a password policy (base64 encoded for ease) named `postgresql`
  - This step ensures that generated passwords adhere to specified policies.
  ```bash
  vault write sys/policies/password/postgresql policy="$vault_password_policy"
  ```

- Enable the database secrets engine:
  - Necessary for Vault to manage database credentials.
  ```bash
  vault secrets enable database
  ```

- Configure PostgreSQL secrets engine with SSL/TLS:
  - Configuration for our database connection named $vault_postgres_user_group.
  - Allow our group role $vault_postgres_user_group to access the database using this connection.
  - Ensures secure connection between Vault and PostgreSQL.
  ```bash
  vault write database/config/$vault_postgres_user_group \
      plugin_name="postgresql-database-plugin" \
      allowed_roles="$vault_postgres_user_group" \
      connection_url="postgresql://{{username}}:{{password}}@$db_host:$db_port/$db_name?sslmode=verify-ca&sslrootcert=/vault/userconfig/vault-postgresql-user-tls-certificate/ca.crt&sslcert=/vault/userconfig/vault-postgresql-user-tls-certificate/tls.crt&sslkey=/vault/userconfig/vault-postgresql-user-tls-certificate/tls.key" \
      max_open_connections="5" \
      max_connection_lifetime="5s" \
      username="$vault_postgres_root_user" \
      password="$vault_postgres_password" \
      password_policy="postgresql"
  ```

### 6. Rotating Credentials and Creating Admin Role
- **Rotate the Root Credentials for Vault-Specific User:**
  - Ensures the password for `$vault_postgres_root_user` is known only to Vault.
  - Use it to rotate the database connection root user's password.
  - This step is crucial for security, making sure that the Vault-specific user's credentials are not accessible outside Vault.
  ```bash
  vault write -force database/rotate-root/$vault_postgres_user_group
  ```

- Create a New Admin Role in Vault for PostgreSQL Management:
  - Defines permissions and access controls for role mentioned above under the allowed_roles key.
  - This role contains SQL directives with placeholders to create and drop the database role.
  - Sets the TTL (Time To Live) for credentials.
  ```bash
  vault write database/roles/$vault_postgres_user_group \
      db_name="$vault_postgres_user_group" \
      creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        ALTER DEFAULT PRIVILEGES FOR ROLE \"{{name}}\" IN SCHEMA public \
        GRANT ALL PRIVILEGES ON TABLES TO $vault_postgres_user_group; \
        ALTER DEFAULT PRIVILEGES FOR ROLE \"{{name}}\" IN SCHEMA public \
        GRANT ALL PRIVILEGES ON SEQUENCES TO $vault_postgres_user_group; \
        ALTER DEFAULT PRIVILEGES FOR ROLE \"{{name}}\" IN SCHEMA public \
        GRANT ALL PRIVILEGES ON FUNCTIONS TO $vault_postgres_user_group; \
        GRANT $vault_postgres_user_group TO \"{{name}}\";" \
      revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";""
      default_ttl="3h" \
      max_ttl="24h"
  ```

- Verify that a new set of database credentials can be acquired:
  - Once the $db_name role is created, verify that a new set of database credentials can be acquired. This ensures that the role is functioning as expected and that Vault is able to generate credentials based on the role definition.
  ```bash
  vault read database/creds/$vault_postgres_user_group
  ```
  - This command will request Vault to create a new set of credentials for the $vault_postgres_user_group role. Vault will then dynamically generate a username and password for PostgreSQL.

- Lookup All Leases for the Admin Role:
  - It's also useful to verify and manage active leases for credentials that have been generated by Vault. This can help in monitoring and auditing credential usage.
  - Note: Access to this path requires appropriate policy permissions in Vault. The following example assumes root access.
  ```bash
  vault list sys/leases/lookup/database/creds/$vault_postgres_user_group
  ```
  - This command lists all the active leases for credentials generated for the $db_name role. Each lease represents a set of credentials that have been provided to a client and are currently active.

### 7. CSI Driver Operations for Kubernetes Integration
- **Enable Kubernetes Authentication in Vault:**
  - **Purpose:** To authenticate Vault with Kubernetes using a Kubernetes Service Account.
    **Intended Action:**
    - Check if Kubernetes authentication is already enabled in Vault.
    - If not, enable the Kubernetes authentication method.
    - This sets up Vault to accept authentication tokens from Kubernetes Service Accounts.

  ```bash
  vault auth list | grep kubernetes
  vault auth enable -default-lease-ttl="1440h" -description="Kubernetes auth method to authenticate with Vault using a Kubernetes Service Account" kubernetes
  ```

- **Configure Kubernetes Auth Method:**
  - **Purpose:** To set up the communication between Vault and the Kubernetes API server.
  - **Intended Action:**
    - Define the Kubernetes API server address and port in Vault's Kubernetes auth method configuration.
    - This ensures that Vault can validate Kubernetes Service Account tokens against the Kubernetes API.
  
  ```bash
  vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:$KUBERNETES_SERVICE_PORT_HTTPS"
  ```

- **Create Vault Policy for Database Secret Access:**
  - **Purpose:** To define a set of permissions in Vault that allows reading database credentials.
  - **Intended Action:**
    - Create a policy in Vault that specifies the capabilities (like "read") on paths (like "database/creds/...").
    - This policy will be used to grant access to the database secrets for the specified role.

  ```bash
  vault policy write $vault_postgres_user_group - <<EOF
  path "database/creds/$vault_postgres_user_group" {
    capabilities = ["read"]
  }
  EOF
  ```

- **Map Kubernetes Service Account to Vault Policy:**
  - **Purpose:** To associate a Kubernetes Service Account with the Vault policy, enabling the Service Account to access database credentials according to the policy.
  - **Intended Action:**
    - Create a role in Vault under the Kubernetes auth method.
    - This role maps the Kubernetes Service Account to the Vault policy, specifying which namespaces the Service Account operates in and what policy it's assigned.

  ```bash
  vault write auth/kubernetes/role/$vault_postgres_user_group \
    bound_service_account_names="$vault_postgres_user_group" \
    bound_service_account_namespaces="default" \
    policies="$vault_postgres_user_group" \
    ttl="1440h"
  ```

- **Update Configuration Files:**
  - **Purpose:** To ensure that your Kubernetes deployment and Vault are correctly configured with the newly created service account and user group details.
  - **Intended Action:**
    - Modify your `values.yaml` or `override.yaml` files with the details of the created service account and user group.
    - This step integrates the Vault configuration into your Kubernetes deployment, ensuring that the services can correctly authenticate and retrieve secrets from Vault.
    

### 8. Additional Considerations
- Regular Auditing and Monitoring:
  - Regularly audit Vault and PostgreSQL logs to monitor access and activities.

- Backup and Disaster Recovery:
  - Implement a backup strategy for Vault's storage backend and PostgreSQL data.

- Vault Policy Management:
  - Define and manage policies in Vault to control who can access what secrets.
