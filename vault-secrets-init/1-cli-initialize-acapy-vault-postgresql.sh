#!/bin/bash

# Script to create a new Vault profile for a new deployment
# Generates:
# - Database name
# - PostgreSQL username
# - Group name
# Then echoes the commands to create the new profile in Vault and a PostgreSQL database

# Function to generate a random lowercase letter
generate_random_letter() {
    echo "$(tr -dc 'a-z' < /dev/urandom | fold -w 1 | head -n 1)"
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

# Normalize deployment name: convert to lowercase, ensure it starts with a lowercase letter, and remove non-letter characters
deploy_name=$(echo "$deploy_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z]//g')
if ! [[ $deploy_name =~ ^[a-z] ]]; then
    deploy_name="$(generate_random_letter)$deploy_name"
fi

# Generate a database name with a Unix timestamp
timestamp=$(date +"%s")
db_name="${deploy_name}_db_${timestamp}"

# PostgreSQL username (maximum 63 characters)
max_length=63
timestamp_length=${#timestamp}
available_length=$((max_length - timestamp_length - 11)) # 11 characters for '_rootuser_'
deploy_name_cut=${deploy_name:0:$available_length}
vault_postgres_root_user="${deploy_name_cut}_rootuser_${timestamp}"

# PostgreSQL password (maximum 100 characters)
# Doesn't need to be too strong since it will be rotated immediately by Vault
pg_password_length=$((RANDOM % 10 + 25)) # Random length between 80 and 99
vault_postgres_password=$(head -c 10000 /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${pg_password_length} | head -n 1)

# Generate group name
vault_postgres_user_group="${deploy_name}_group_${timestamp}"

# Determine the project root directory relative to the script location
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Base64 encode password policy
vault_password_policy=$(cat ${project_root_dir}/policies/password-policy.hcl | base64)

# Define file name for the vault profile
vault_profile_file="1-initialize-bpa-vault-postgresql.txt"

# Acquire db_host from .bpa.db.host path in ../override.yaml file using yq
db_host=$(yq e '.bpa.db.host' "${project_root_dir}/override.yaml")

# Acquire db_port from .bpa.db.port path in ../override.yaml file using yq
db_port=$(yq e '.bpa.db.port' "${project_root_dir}/override.yaml")

# Password policy name
postgresql_password_policy_name="postgresql"

# Write a series of SQL commands and Vault configurations to 'vault_profile_file', 
# outlining the steps for creating a PostgreSQL database, 
# setting up user roles and permissions, and configuring the Vault database secrets engine for the new deployment


echo "# Follow these SQL steps using the \"postgres\" admin user to create a new db profile:" >| $vault_profile_file

echo -e "\n# Profile: " >> $vault_profile_file
echo "# - db_host: {{ .Values.bpa.db.host }}" >> $vault_profile_file
echo "# - db_port: {{ .Values.bpa.db.port }}" >> $vault_profile_file
echo "# Make sure to subsitute with actual values in your values.yaml file" >> $vault_profile_file

## Create a postgresql "group"
echo -e "\n# ==============================" >> $vault_profile_file
echo "# 1. Create a postgresql \"group\"" >> $vault_profile_file
echo -e "# ==============================\n" >> $vault_profile_file
echo "CREATE DATABASE $db_name;
REVOKE ALL ON DATABASE $db_name FROM PUBLIC;
REVOKE ALL ON DATABASE $db_name FROM PUBLIC;
CREATE ROLE $vault_postgres_user_group;
GRANT CONNECT ON DATABASE $db_name TO $vault_postgres_user_group;
GRANT ALL PRIVILEGES ON SCHEMA public TO $vault_postgres_user_group;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $vault_postgres_user_group;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $vault_postgres_user_group;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO $vault_postgres_user_group;
ALTER DATABASE $db_name OWNER TO $vault_postgres_user_group;" >> $vault_profile_file

## Create a postgresql user
echo -e "\n# ===========================" >> $vault_profile_file
echo "# 2. Create a postgresql user" >> $vault_profile_file
echo -e "# ===========================\n" >> $vault_profile_file
echo "CREATE USER $vault_postgres_root_user WITH ENCRYPTED PASSWORD '$vault_postgres_password' CREATEROLE;" >> $vault_profile_file

## Add user to group
echo -e "\n# ====================" >> $vault_profile_file
echo "# 3. Add user to group" >> $vault_profile_file
echo -e "# ====================\n" >> $vault_profile_file
echo "GRANT $vault_postgres_user_group TO $vault_postgres_root_user;" >> $vault_profile_file

## Create a Trigger to set Ownership of Created Objects
echo -e "\n# =======================================================" >> $vault_profile_file
echo "# 4. Create a Trigger to set Ownership of Created Objects" >> $vault_profile_file
echo -e "# =======================================================\n" >> $vault_profile_file
echo "CREATE OR REPLACE FUNCTION ${vault_postgres_user_group}_trg_create_set_owner()
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

CREATE EVENT TRIGGER ${vault_postgres_user_group}_trg_create_set_owner_trigger
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'CREATE FUNCTION', 'CREATE SCHEMA', 'CREATE SEQUENCE')
  EXECUTE PROCEDURE ${vault_postgres_user_group}_trg_create_set_owner();" >> $vault_profile_file


## Setup Password Policy and Database Secrets Engine
echo -e "\n# ====================================================" >> $vault_profile_file
echo "# 5. Setup Password Policy and Database Secrets Engine" >> $vault_profile_file
echo -e "# ====================================================\n" >> $vault_profile_file

echo -e "# Configure Policy: \n" >> $vault_profile_file
echo "vault write sys/policies/password/$postgresql_password_policy_name policy=\"$vault_password_policy\"" >> $vault_profile_file

echo -e "\n# Enable Database Secrets Engine: \n" >> $vault_profile_file
echo "vault secrets enable database" >> $vault_profile_file

echo -e "\n# Configure Database Secrets Engine \n" >> $vault_profile_file
echo "vault write database/config/$vault_postgres_user_group \\" >> $vault_profile_file
echo "    plugin_name=\"postgresql-database-plugin\" \\" >> $vault_profile_file
echo "    allowed_roles=\"$vault_postgres_user_group\" \\" >> $vault_profile_file
echo "    connection_url=\"postgresql://{{username}}:{{password}}@$db_host:$db_port/$db_name?sslmode=disable\" \\" >> $vault_profile_file
# echo "    connection_url=\"postgresql://{{username}}:{{password}}@$db_host:$db_port/$db_name?sslmode=verify-ca&sslrootcert=/vault/userconfig/vault-postgresql-user-tls-certificate/ca.crt&sslcert=/vault/userconfig/vault-postgresql-user-tls-certificate/tls.crt&sslkey=/vault/userconfig/vault-postgresql-user-tls-certificate/tls.key\" \\" >> $vault_profile_file
echo "    max_open_connections=\"5\" \\" >> $vault_profile_file
echo "    max_connection_lifetime=\"5s\" \\" >> $vault_profile_file
echo "    username=\"$vault_postgres_root_user\" \\" >> $vault_profile_file
echo "    password=\"$vault_postgres_password\" \\" >> $vault_profile_file
echo "    password_policy=\"$postgresql_password_policy_name\"" >> $vault_profile_file

echo -e "\n# =========================================" >> $vault_profile_file
echo "# 6. Rotate Root Credentials for connection" >> $vault_profile_file
echo -e "# =========================================\n" >> $vault_profile_file
echo "vault write -force database/rotate-root/$vault_postgres_user_group" >> $vault_profile_file

echo -e "\n# ====================================================" >> $vault_profile_file
echo "# 6. Create Dynamic Credentials Based on Previous Role" >> $vault_profile_file
echo -e "# ====================================================\n" >> $vault_profile_file
echo "vault write database/roles/$vault_postgres_user_group \\" >> $vault_profile_file
echo "    db_name=\"$vault_postgres_user_group\" \\" >> $vault_profile_file
echo "    creation_statements=\"CREATE ROLE \\\"{{name}}\\\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \\" >> $vault_profile_file
echo "      GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $vault_postgres_user_group; \\" >> $vault_profile_file
echo "      GRANT SELECT, USAGE, UPDATE ON ALL SEQUENCES IN SCHEMA public TO $vault_postgres_user_group; \\" >> $vault_profile_file
echo "      GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO $vault_postgres_user_group; \\" >> $vault_profile_file
echo "      GRANT $vault_postgres_user_group TO \\\"{{name}}\\\";\" \\" >> $vault_profile_file
echo "    revocation_statements=\"DROP ROLE IF EXISTS \\\"{{name}}\\\";\" \\" >> $vault_profile_file
echo "    default_ttl=\"3h\" \\" >> $vault_profile_file
echo "    max_ttl=\"24h\"" >> $vault_profile_file


echo -e "\n# UPDATE YOUR values.yaml/override.yaml FILE WITH THE FOLLOWING: \n" >> $vault_profile_file

echo -e "{{ .Values.vault.postgresUserGroup }} -    $vault_postgres_user_group\n" >> $vault_profile_file
echo -e "{{ .Values.bpa.db.database }} - $db_name\n" >> $vault_profile_file

echo -e "\n# View Results in ./new-vault-profile.txt"

# CSI DRIVER OPERATIONS

# 1. Ensure vault auth enable kubernetes

# List all auth methods
echo -e "\nvault auth list | grep kubernetes\n" >> $vault_profile_file

# Enable kubernetes auth method if not enabled
echo -e "\nvault auth enable -default-lease-ttl=\"1440h\" -description=\"Kubernetes auth method to authenticate with Vault using a Kubernetes Service Account\" kubernetes\n" >> $vault_profile_file

# Configure the auth method with the Kubernetes host
echo -e "\nConfigure the auth method with the Kubernetes host\n" >> $vault_profile_file
echo -e "\nvault write auth/kubernetes/config kubernetes_host=\"https://$KUBERNETES_PORT_443_TCP_ADDR:$KUBERNETES_SERVICE_PORT_HTTPS\"\n" >> $vault_profile_file

# 2. Create a policy that will be used to grant a role permission to read the database secret:
echo -e "\nCreating a policy that will be used to grant a role permission to read the database secret...\n" >> $vault_profile_file
echo "vault policy write $vault_postgres_user_group - <<EOF" >> $vault_profile_file
echo "path \"database/creds/$vault_postgres_user_group\" {" >> $vault_profile_file
echo "  capabilities = [\"read\"]" >> $vault_profile_file
echo "}" >> $vault_profile_file
echo "EOF" >> $vault_profile_file

# 3. Create a role that maps the Kubernetes Service Account to the Vault policy
echo -e "\nCreating a role that maps the Kubernetes Service Account to the Vault policy...\n" >> $vault_profile_file
echo "vault write auth/kubernetes/role/$vault_postgres_user_group \\" >> $vault_profile_file
echo "    bound_service_account_names=\"$vault_postgres_user_group\" \\" >> $vault_profile_file
echo "    bound_service_account_namespaces=\"default\" \\" >> $vault_profile_file
echo "    policies=\"$vault_postgres_user_group\" \\" >> $vault_profile_file
echo "    ttl=\"1440h\"" >> $vault_profile_file

# 4. Echo the values to update in values.yaml/override.yaml
echo -e "\n# CRITICAL - UPDATE YOUR values.yaml/override.yaml FILE WITH THE FOLLOWING: \n"

echo -e "{{ .Values.bpa.serviceAccount.name }}:    $vault_postgres_user_group\n"
echo -e "{{ .Values.vault.postgresUserGroup }}:    $vault_postgres_user_group\n"
echo -e "{{ .Values.bpa.db.database }}: $db_name\n"

# Echo the vault read path for the postgresql role
echo -e "\n# Vault read path for the postgresql role\n"
echo -e "vault read database/creds/$vault_postgres_user_group\n"
