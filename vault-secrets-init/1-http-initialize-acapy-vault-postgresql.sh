#!/bin/bash

set -e

# This script creates a new Vault profile for an ACA-Py deployment.

# Function to generate a random lowercase letter prefix
prefix_acapy() {
  echo "acapy"
}

# Function to generate a random word containing only letters
generate_random_word() {
  shuf -n 1 /usr/share/dict/words | tr -cd '[:alpha:]'
}

# Collect deployment name from user input, or use a random word if left blank
read -p "Enter a name for this deployment (random word will be used if left blank): " deploy_name
if [ -z "$deploy_name" ]; then
  echo "No deployment name entered. Using a random word."
  deploy_name=$(generate_random_word)
fi

# Normalize deployment name by converting to lowercase, replacing spaces with hyphens, and ensuring it starts with a lowercase letter
deploy_name=$(echo "$deploy_name" | tr '[:upper:]' '[:lower:]' | sed 's/ //g' | sed 's/[^a-z0-9]//g')
if ! [[ $deploy_name =~ ^[a-z] ]]; then
  deploy_name="$(prefix_acapy)$deploy_name"
fi

# Generate database and related configurations
timestamp=$(date +"%s")
db_name="${deploy_name}${timestamp}database"  # Database name including a Unix timestamp
max_length=63
timestamp_length=${#timestamp}
available_length=$((max_length - timestamp_length - 9))  # 9 characters for 'rootuser'
deploy_name_cut=${deploy_name:0:$available_length}
vault_postgres_root_user="${deploy_name_cut}${timestamp}rootuser"  # PostgreSQL username
pg_password_length=$((RANDOM % 10 + 25))  # Password length between 25 and 34
vault_postgres_password=$(head -c 10000 /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${pg_password_length} | head -n 1)  # PostgreSQL password
vault_postgres_user_group="${deploy_name}${timestamp}group"  # Group name

# Retrieve project root directory
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Load and encode password policy from a file
vault_password_policy=$(cat ${project_root_dir}/policies/password-policy.hcl | base64 -w 0)

# Retrieve database and vault configuration using 'yq' from an override YAML file
db_host=$(yq e '.db.host' "${project_root_dir}/override.yaml")
if [ -z "$db_host" ] || [ "$db_host" = "null" ]; then
    echo "Error: db_host not set or is null. Exiting."
    exit 1
fi

postgres_ip=$(yq e '.vault.postgres_ip' "${project_root_dir}/override.yaml")
if [ -z "$postgres_ip" ] || [ "$postgres_ip" = "null" ]; then
    echo "Error: postgres_ip not set or is null. Exiting."
    exit 1
fi

db_port=$(yq e '.db.port' "${project_root_dir}/override.yaml")
if [ -z "$db_port" ] || [ "$db_port" = "null" ]; then
    echo "Error: db_port not set or is null. Exiting."
    exit 1
fi

vault_server_url=$(yq e '.vault.vault_server_url' "${project_root_dir}/override.yaml")
if [ -z "$vault_server_url" ] || [ "$vault_server_url" = "null" ]; then
    echo "Error: vault_server_url not set or is null. Exiting."
    exit 1
fi


# Process Vault secrets
secrets_file="${project_root_dir}/vault-secrets-init/0-vault-init.txt"
encrypted_token=$(grep "root_token" $secrets_file | awk '{print $NF}')  # Retrieve the root token from the file
vault_auth_token=$(echo "$encrypted_token" | base64 --d | gpg -d)  # Decrypt the root token

# Vault configuration for PostgreSQL
postgresql_password_policy_name="postgresql"
postgresql_key_name="postgresql_kv_secret"
postgresql_secret_path="secret/postgresql/admin"

# Retrieve PostgreSQL admin credentials from Vault
postgresql_admin_username=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$postgresql_secret_path/data/$postgresql_key_name | jq -r '.data.data.postgresql_admin_username')
postgresql_admin_password=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$postgresql_secret_path/data/$postgresql_key_name | jq -r '.data.data.postgresql_admin_password')

# Set the PGPASSWORD environment variable
export PGPASSWORD="$postgresql_admin_password"

## Create a postgresql "group", user and database
echo -e "\n# ===================================================="
echo "# 1. Create a postgresql \"group\"", user and database
echo -e "# ====================================================\n"

# Connect to PostgreSQL and execute the following:
# We utilize the 'postgres' schema as ACA-Py and Askar default to it.
# Currently, there's no option to alter the default schema for ACA-Py and Askar.

psql -U "$postgresql_admin_username" -h "$postgres_ip" -p $db_port <<EOF
CREATE DATABASE "$db_name";
REVOKE ALL ON DATABASE "$db_name" FROM PUBLIC;

\connect "$db_name"

CREATE SCHEMA IF NOT EXISTS postgres;

CREATE ROLE "$vault_postgres_user_group";
CREATE USER "$vault_postgres_root_user" WITH ENCRYPTED PASSWORD '$vault_postgres_password' CREATEDB CREATEROLE;
GRANT "$vault_postgres_user_group" TO "$vault_postgres_root_user";

GRANT CONNECT ON DATABASE "$db_name" TO "$vault_postgres_user_group";
ALTER DATABASE "$db_name" OWNER TO "$vault_postgres_user_group";

GRANT ALL PRIVILEGES ON SCHEMA postgres TO "$vault_postgres_user_group";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA postgres TO "$vault_postgres_user_group";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA postgres TO "$vault_postgres_user_group";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA postgres TO "$vault_postgres_user_group";
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
    IF obj.schema_name IN ('postgres') THEN
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

# Configure Database Secrets Engine
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

# Add a role with CREATEDB privileges so that acapy can create a database
# Acapy currently doesn't create wallets in existing databases, so this is required
role_payload=$(
  cat <<EOF
{
  "db_name": "$vault_postgres_user_group",
  "creation_statements": [
    "CREATE ROLE \"{{name}}\" WITH LOGIN CREATEDB PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'",
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

# The following values will be updated automatically in override-db.yaml file using yq:
# db.database: $db_name
# serviceAccount.name: $vault_postgres_user_group
# vault.postgresUserGroup: $vault_postgres_user_group
# vault.kubernetes_authentication_role_names.database: $database_auth_role_name
db_name_temp=${db_name}_temp
echo -e "\n# ========== CRITICAL UPDATE REQUIRED =========="

echo -e "\n# =========================================================================================="
echo "Updating your override-db.yaml file with the following:"
echo -e " - serviceAccount.name: $vault_postgres_user_group"
echo -e " - db.database: $db_name_temp"
echo -e " - vault.postgresUserGroup: $vault_postgres_user_group"
echo -e " - vault.kubernetes_authentication_role_names.database: $database_auth_role_name"
echo -e "# ==============================================================================================\n"

yq e -i ".serviceAccount.name = \"$vault_postgres_user_group\"" "${project_root_dir}/override-db.yaml"
yq e -i ".db.database = \"$db_name_temp\"" "${project_root_dir}/override-db.yaml"
yq e -i ".vault.postgresUserGroup = \"$vault_postgres_user_group\"" "${project_root_dir}/override-db.yaml"
yq e -i ".vault.kubernetes_authentication_role_names.database = \"$database_auth_role_name\"" "${project_root_dir}/override-db.yaml"

echo -e "# ------------------------------------------------\n"

# Echo the vault read path for the postgresql role
echo -e "# Vault PostgreSQL Role Access Information"
echo -e "# HTTP Read Path:"
echo -e "  $vault_server_url/v1/database/creds/$vault_postgres_user_group\n"
# CLI read command for the postgresql role
echo -e "# CLI Read Command:"
echo -e "  vault read database/creds/$vault_postgres_user_group\n"
echo -e "# ===============================================\n"