#!/bin/bash

set -e

# Script to create a new Vault profile for a new acapy deployment
# Generates:
# - Database name
# - PostgreSQL username
# - Group name
# - postgres_ip
# - db_port
# Then echoes the commands to create the new profile in Vault and a PostgreSQL database

# Function to add "acapy" to the beginning of a random word
prefix_acapy() {
  echo "acapy"
}

# Function to generate a random word containing only letters
generate_random_word() {
  shuf -n 1 /usr/share/dict/words | tr -cd '[:alpha:]'
}

# Ask for deployment name, use random word if left blank
read -p "Enter a name for this deployment (random word will be used if left blank): " deploy_name
if [ -z "$deploy_name" ]; then
  echo "No deployment name entered. Using a random word."
  deploy_name=$(generate_random_word)
fi

# Normalize deployment name: 
# 1. Convert to lowercase
# 2. Replace spaces with hyphens
# 3. Ensure it starts with a lowercase letter
# 4. Remove non-letter characters except hyphens
deploy_name=$(echo "$deploy_name" | tr '[:upper:]' '[:lower:]' | sed 's/ //g' | sed 's/[^a-z0-9]//g')

# Add acapy to the begining of every deployment name
deploy_name="$(prefix_acapy)$deploy_name"

# Generate a database name with a Unix timestamp
timestamp=$(date +"%s")
db_name="${deploy_name}${timestamp}database"

# PostgreSQL username (maximum 63 characters)
max_length=63
timestamp_length=${#timestamp}
available_length=$((max_length - timestamp_length - 11)) # 11 characters for '_rootuser_'
deploy_name_cut=${deploy_name:0:$available_length}
vault_postgres_root_user="${deploy_name_cut}${timestamp}rootuser"

# PostgreSQL password (maximum 100 characters)
# Doesn't need to be too strong since it will be rotated immediately by Vault
pg_password_length=$((RANDOM % 10 + 25)) # Random length between 80 and 99
vault_postgres_password=$(head -c 10000 /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${pg_password_length} | head -n 1)

# Generate group name
vault_postgres_user_group="${deploy_name}${timestamp}group"

# Determine the project root directory relative to the script location
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Base64 encode password policy
vault_password_policy=$(cat ${project_root_dir}/policies/password-policy.hcl | base64 -w 0)

# Acquire db_host from .db.host path in ../override.yaml file using yq
db_host=$(yq e '.db.host' "${project_root_dir}/override.yaml")

# Acquire postgres_ip from .vault.postgres_ip path in ../override.yaml file using yq
postgres_ip=$(yq e '.vault.postgres_ip' "${project_root_dir}/override.yaml")

# Acquire db_port from .db.port path in ../override.yaml file using yq
db_port=$(yq e '.db.port' "${project_root_dir}/override.yaml")


# Vault secrets file
secrets_file="${project_root_dir}/vault-secrets-init/0-vault-init.txt"

# Retrieve the root token from the file
encrypted_token=$(grep "root_token" $secrets_file | awk '{print $NF}')

# Decrypt the root token
vault_auth_token=$(echo "$encrypted_token" | base64 --d | gpg -d)

# Acquire vault_server_url from .vault.vault_server_url path in ../override.yaml file using yq
vault_server_url=$(yq e '.vault.vault_server_url' "${project_root_dir}/override.yaml")

# Password policy name
postgresql_password_policy_name="postgresql"

# Set postgresql_key_name value
postgresql_key_name="postgresql_kv_secret"

# Set postgresql_secret_path value
postgresql_secret_path="secret/postgresql/admin"

# Retrieve admin username from vault at postgresql_secret_path and postgresql_key_name
postgresql_admin_username=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$postgresql_secret_path/data/$postgresql_key_name | jq -r '.data.data.postgresql_admin_username')

# Retrieve admin password from vault at postgresql_secret_path and postgresql_key_name
postgresql_admin_password=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$postgresql_secret_path/data/$postgresql_key_name | jq -r '.data.data.postgresql_admin_password')

# Set the PGPASSWORD environment variable
export PGPASSWORD="$postgresql_admin_password"

## Create a postgresql "group" using the admin credentials and sql statements
echo -e "\n# =============================="
echo "# 1. Create a postgresql \"group\""
echo -e "# ==============================\n"

# Execute the SQL commands using psql
psql -U "$postgresql_admin_username" -h "$postgres_ip" -p $db_port <<EOF
CREATE DATABASE "$db_name";
REVOKE ALL ON DATABASE "$db_name" FROM PUBLIC;
CREATE ROLE "$vault_postgres_user_group";
GRANT CONNECT ON DATABASE "$db_name" TO "$vault_postgres_user_group";
GRANT ALL PRIVILEGES ON SCHEMA public TO "$vault_postgres_user_group";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$vault_postgres_user_group";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$vault_postgres_user_group";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "$vault_postgres_user_group";
ALTER DATABASE "$db_name" OWNER TO "$vault_postgres_user_group";
EOF

## Create a postgresql user
echo -e "\n# ==========================="
echo "# 2. Create a postgresql user"
echo -e "# ===========================\n"
psql -U "$postgresql_admin_username" -h "$postgres_ip" -p $db_port <<EOF
CREATE USER "$vault_postgres_root_user" WITH ENCRYPTED PASSWORD '$vault_postgres_password' CREATEROLE;
EOF

## Add user to group
echo -e "\n# ===================="
echo "# 3. Add user to group"
echo -e "# ====================\n"
psql -U "$postgresql_admin_username" -h "$postgres_ip" -p $db_port <<EOF
GRANT "$vault_postgres_user_group" TO "$vault_postgres_root_user";
EOF

## Create a Trigger to set Ownership of Created Objects
echo -e "\n# ========================================================"
echo "# 4. Create a Trigger to set Ownership of Created Objects"
echo -e "# ========================================================\n"

create_trigger_owner=${vault_postgres_user_group}_trg_create_set_owner
trigger_the_owner=${vault_postgres_user_group}_trg_create_set_owner_trigger

psql -U "$postgresql_admin_username" -h "$postgres_ip" -p $db_port -d $db_name <<EOF
CREATE OR REPLACE FUNCTION $create_trigger_owner()
  RETURNS event_trigger
  LANGUAGE plpgsql
AS \$\$
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
\$\$;

CREATE EVENT TRIGGER $trigger_the_owner
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'CREATE FUNCTION', 'CREATE SCHEMA', 'CREATE SEQUENCE')
  EXECUTE PROCEDURE $create_trigger_owner();
EOF

# Unset the PGPASSWORD environment variable
unset PGPASSWORD

## Setup Password Policy and Database Secrets Engine
echo -e "\n# ===================================================="
echo "# 5. Setup Password Policy and Database Secrets Engine"
echo -e "# ====================================================\n"

# postgresql password policy
echo -e "\n# Create postgresql password policy... \n"
postgresql_password_policy_payload=$(
  cat <<EOF
{
  "policy": "$vault_password_policy"
}
EOF
)

# Ensure postgresql password policy exists

# Read the postgresql password policy to see if it exists
get_password_policy=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/sys/policies/password/$postgresql_password_policy_name)

# If the postgresql password policy exists, acknowledge it, if not, create it
if echo "$get_password_policy" | jq -e '.["errors"]' > /dev/null; then
    echo "Postgresql password policy does not exist."
    echo "Creating postgresql password policy..."
    curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$postgresql_password_policy_payload" $vault_server_url/v1/sys/policies/password/$postgresql_password_policy_name
    echo "Postgresql password policy now created."
else
    echo "Postgresql password policy already exists."
fi

# Enable Database Secrets Engine

# Database engine payload
echo -e "\n# Enable Database Secrets Engine... \n"
database_engine_payload=$(
  cat <<EOF
{
  "type": "database"
}
EOF
)

# Ensure Database Secrets Engine is enabled

# List all secret engines
list_secret_engine=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" "$vault_server_url/v1/sys/mounts")

# Check if 'database/' is in the list_secret_engine aka enabled already
if echo "$list_secret_engine" | jq -e '.["database/"]' > /dev/null; then
    echo "Database Secrets Engine is enabled."
else
    # Enable Database Secrets Engine
    echo "Database Secrets Engine is not enabled."
    echo "Enabling Database Secrets Engine..."
    curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$database_engine_payload" $vault_server_url/v1/sys/mounts/database
    echo "Database Secrets Engine now enabled."
fi

# Configure Database Secrets Engine for the $vault_postgres_user_group path
echo -e "\n# Configure Database Secrets Engine... \n"
database_config_payload=$(
  cat <<EOF
{
  "plugin_name": "postgresql-database-plugin",
  "allowed_roles": "$vault_postgres_user_group",
  "connection_url": "postgresql://{{username}}:{{password}}@$db_host:$db_port/$db_name?sslmode=disable",
  "max_open_connections": "5",
  "max_connection_lifetime": "5s",
  "username": "$vault_postgres_root_user",
  "password": "$vault_postgres_password",
  "password_policy": "$postgresql_password_policy_name"
}
EOF
)
curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$database_config_payload" $vault_server_url/v1/database/config/$vault_postgres_user_group

# Rotate Root Credentials for connection
echo -e "\n# ========================================="
echo "# 6. Rotate Root Credentials for connection"
echo -e "# =========================================\n"
curl -k --header "X-Vault-Token: $vault_auth_token" --request POST $vault_server_url/v1/database/rotate-root/$vault_postgres_user_group

# Create Role Template
echo -e "\n# ===================================================="
echo "# 6. Create Dynamic Credentials Based on Previous Role"
echo -e "# ====================================================\n"

role_payload=$(
  cat <<EOF
{
  "db_name": "$vault_postgres_user_group",
  "creation_statements": [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'",
    "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $vault_postgres_user_group",
    "GRANT SELECT, USAGE, UPDATE ON ALL SEQUENCES IN SCHEMA public TO $vault_postgres_user_group",
    "GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO $vault_postgres_user_group",
    "GRANT $vault_postgres_user_group TO \"{{name}}\""
  ],
  "revocation_statements": [
    "DROP ROLE IF EXISTS \"{{name}}\""
  ],
  "default_ttl": "3h",
  "max_ttl": "24h"
}
EOF
)
curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$role_payload" $vault_server_url/v1/database/roles/$vault_postgres_user_group


# CSI DRIVER OPERATIONS

# 1. Ensure vault auth enable kubernetes

# List all auth methods
list_auth_methods=$(curl -k --header "X-Vault-Token: $vault_auth_token" "$vault_server_url/v1/sys/auth")

# Retrieve kubernetes port 443 tcp address
KUBERNETES_PORT_443_TCP_ADDR=$(kubectl get service kubernetes -o jsonpath='{.spec.clusterIP}')

# Retrieve kubernetes service port
KUBERNETES_SERVICE_PORT=$(kubectl get service kubernetes -o jsonpath='{.spec.ports[0].port}')

# Kubernetes auth config payload
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

# Kubernetes auth config payload
kubernetes_auth_config_payload=$(
  cat <<EOF
{
  "kubernetes_host": "https://$KUBERNETES_PORT_443_TCP_ADDR:$KUBERNETES_SERVICE_PORT"
}
EOF
)

# Check if 'kubernetes/' is in the response aka enabled already
if echo "$list_auth_methods" | jq -e '.["kubernetes/"]' > /dev/null; then
    echo "Kubernetes auth method is already enabled."
else
    # Enable kubernetes auth method
    echo "Kubernetes auth method is not enabled."
    echo "Enabling kubernetes auth method..."
    curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$kubernetes_auth_payload" "$vault_server_url/v1/sys/auth/kubernetes"

    # Configure the auth method with the Kubernetes host
    echo "Configuring the auth method with the Kubernetes host..."

    # Configure the auth method with the Kubernetes host
    curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$kubernetes_auth_config_payload" "$vault_server_url/v1/auth/kubernetes/config"
    echo "Kubernetes auth method now enabled."
fi

# 2. Create a policy that will be used to grant a role permission to read the database secret:
echo "Creating a policy that will be used to grant a role permission to read the database secret..."

# Policy name
path_to_database_policy_name="database/creds/$vault_postgres_user_group"
database_authn_policy_name=$(echo $path_to_database_policy_name | sed 's/\//_/g')_service_account_policy

database_auth_policy_payload=$(
  cat <<EOF
{
  "policy": "path \"database/creds/$vault_postgres_user_group\" {capabilities = [\"read\"]}"
}
EOF
)
curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$database_auth_policy_payload" "$vault_server_url/v1/sys/policies/acl/$database_authn_policy_name"

# 3. Create a role that maps a Kubernetes Service Account to the policy:
echo "Creating a role that maps a Kubernetes Service Account to the policy..."


vault_service_account_name=$vault_postgres_user_group

# Role name
database_auth_role_name=$(echo $path_to_database_policy_name | sed 's/\//_/g')_service_account_role

role_payload=$(
  cat <<EOF
{
  "bound_service_account_names": "$vault_service_account_name",
  "bound_service_account_namespaces": "default",
  "policies": ["$database_authn_policy_name"],
  "ttl": "768h"
}
EOF
)
curl -k --header "X-Vault-Token: $vault_auth_token" --request POST --data "$role_payload" "$vault_server_url/v1/auth/kubernetes/role/$database_auth_role_name"

# 4. Echo the values to update in values.yaml/override.yaml
echo -e "\n# CRITICAL - UPDATE YOUR values.yaml/override.yaml FILE WITH THE FOLLOWING: \n"
echo -e "{{ .Values.bpa.serviceAccount.name }}:  $vault_postgres_user_group\n"
echo -e "{{ .Values.bpa.db.database }}: $db_name\n"

echo -e "{{ .Values.vault.postgresUserGroup }}:  $vault_postgres_user_group\n"
echo -e "{{ .Values.vault.kubernetes_authentication_role_names.database }}: $database_auth_role_name\n"

# Echo the vault read path for the postgresql role
echo -e "Http Read Path: $vault_server_url/v1/database/creds/$vault_postgres_user_group\n"
# CLI read command for the postgresql role
echo -e "CLI READ COMMAND: vault read database/creds/$vault_postgres_user_group\n"