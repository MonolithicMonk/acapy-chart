#!/bin/bash


# Determine the project root directory
project_root_dir="$(dirname "$(cd "$(dirname "$0")" && pwd)")"

# Acquire vault_server_url from .vault.vault_server_url path in ../override-db.yaml file using yq
vault_server_url=$(yq e '.vault.vault_server_url' "${project_root_dir}/override-db.yaml")

vault_postgres_user_group=$(yq e '.vault.postgresUserGroup' "${project_root_dir}/override-db.yaml")

vault_server_url=$(yq e '.vault.vault_server_url' "${project_root_dir}/override-db.yaml")
if [ -z "$vault_server_url" ] || [ "$vault_server_url" = "null" ]; then
    echo "Error: vault_server_url not set or is null. Exiting."
    exit 1
fi

# Retrieve database and vault configuration using 'yq' from an override YAML file
db_name=$(yq e '.db.database' "${project_root_dir}/override-db.yaml")
if [ -z "$db_name" ] || [ "$db_name" = "null" ]; then
    echo "Error: db_name not set or is null. Exiting."
    exit 1
fi

db_host=$(yq e '.db.host' "${project_root_dir}/override-db.yaml")
if [ -z "$db_host" ] || [ "$db_host" = "null" ]; then
    echo "Error: db_host not set or is null. Exiting."
    exit 1
fi

db_port=$(yq e '.db.port' "${project_root_dir}/override-db.yaml")
if [ -z "$db_port" ] || [ "$db_port" = "null" ]; then
    echo "Error: db_port not set or is null. Exiting."
    exit 1
fi

postgres_ip=$(yq e '.vault.postgres_ip' "${project_root_dir}/override-db.yaml")
if [ -z "$postgres_ip" ] || [ "$postgres_ip" = "null" ]; then
    echo "Error: postgres_ip not set or is null. Exiting."
    exit 1
fi


# Process Vault secrets
secrets_file="${project_root_dir}/vault-secrets-init/0-vault-init.txt"
encrypted_token=$(grep "root_token" $secrets_file | awk '{print $NF}') 
vault_auth_token=$(echo "$encrypted_token" | base64 --d | gpg -d)  # Decrypt the root token

postgresql_key_name="postgresql_kv_secret"
postgresql_secret_path="secret/postgresql/admin"

# Retrieve PostgreSQL admin credentials from Vault
postgresql_admin_username=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$postgresql_secret_path/data/$postgresql_key_name | jq -r '.data.data.postgresql_admin_username')
postgresql_admin_password=$(curl -s -k --header "X-Vault-Token: $vault_auth_token" $vault_server_url/v1/$postgresql_secret_path/data/$postgresql_key_name | jq -r '.data.data.postgresql_admin_password')

# Set the PGPASSWORD environment variable
export PGPASSWORD="$postgresql_admin_password"


# Strip the string "_temp" from the end of $db_name
db_name_stripped=${db_name%_temp}

# Drop the existing database
echo -e "\n# =========================================================================================="
echo "# 1. Copy the contents of $db_name_stripped database to a file using pg_dump..."
echo -e "# ==========================================================================================\n"
# Create a Duplicate of $db_name_stripped using pg_dump
pg_dump -U "$postgresql_admin_username" -h "$postgres_ip" -p "$db_port" -d "$db_name" -Fc > "${db_name_stripped}.dump"


# Restore the dump into the $db_name_stripped database
echo -e "\n# =========================================================================================="
echo "# 2. Restore the dump into target db - $db_name_stripped database..."
echo -e "# ==========================================================================================\n"
pg_restore -U "$postgresql_admin_username" -h "$postgres_ip" -p $db_port -d "$db_name_stripped" "${db_name_stripped}.dump"

db_name=$db_name_stripped

# Reassign ownership of the database to the postgres group based on the following:
echo -e "\n# ================================================================"
echo "# 3. Reassign ownership of $db_name to $vault_postgres_user_group"
echo -e "# ================================================================\n"

psql -U "$postgresql_admin_username" -h "$postgres_ip" -p $db_port -d $db_name <<EOF
REVOKE ALL ON DATABASE "$db_name" FROM PUBLIC;

GRANT CONNECT ON DATABASE "$db_name" TO "$vault_postgres_user_group";
ALTER DATABASE "$db_name" OWNER TO "$vault_postgres_user_group";

CREATE SCHEMA IF NOT EXISTS public;

ALTER SCHEMA public OWNER TO "$vault_postgres_user_group";
GRANT ALL PRIVILEGES ON SCHEMA public TO "$vault_postgres_user_group";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$vault_postgres_user_group";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$vault_postgres_user_group";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "$vault_postgres_user_group";
EOF

## Create a Trigger to set Ownership of Created Objects
echo -e "\n# ========================================================"
echo "# 4. Creating a Trigger to set Ownership of Created Objects..."
echo -e "# ========================================================\n"

create_trigger_owner=${vault_postgres_user_group}_trg_create_set_owner_public
trigger_the_owner=${vault_postgres_user_group}_trg_create_set_owner_trigger_public

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


echo -e "\n# ========================================================"
echo "# 5. Updating the $db_name in the override-db.yaml file..."
echo -e "# ========================================================\n"
# Update the $db_name in the override-db.yaml file with the new $db_name using yq
yq e -i ".db.database = \"$db_name\"" "${project_root_dir}/override-db.yaml"

# Get chart name from ${project_root_dir}/Chart.yaml using yq
chart_name=$(yq e '.name' "${project_root_dir}/Chart.yaml")

# Get chart version from ${project_root_dir}/Chart.yaml using yq
chart_version=$(yq e '.version' "${project_root_dir}/Chart.yaml")

# Use helm list to get all releases, then grep to filter by chart name and version
release_name=$(helm list -A --output json | jq -r --arg chart_name "$chart_name" --arg chart_version "$chart_version" '.[] | select(.chart == ($chart_name + "-" + $chart_version)) | .name')

# upgrade the helm release
echo -e "\n# ========================================================"
echo "# 6. Upgrading the helm release..."
echo -e "# ========================================================\n"
helm upgrade -f "${project_root_dir}/override.yaml" -f "${project_root_dir}/override-db.yaml" "$release_name" "${project_root_dir}"

# Check if pod has fully terminated

# Get pods using kubectl and filter by release name whose status is not Terminating
pod_name=$(kubectl get pods -o json | jq -r --arg release_name "$release_name" '.items[] | select(.metadata.name | contains($release_name)) | select(.status.phase != "Terminating") | .metadata.name')

# Wait for the pod to terminate before proceeding to the next step
while [ ! -z "$pod_name" ]; do
    echo "Waiting for pod $pod_name to terminate..."
    sleep 5
    pod_name=$(kubectl get pods -o json | jq -r --arg release_name "$release_name" '.items[] | select(.metadata.name | contains($release_name)) | select(.status.phase != "Terminating") | .metadata.name')
done

# Drop the dumped database
echo -e "\n# ========================================================"
echo "# 7. Dropping the dumped database..."
echo -e "# ========================================================\n"
dropdb -U "$postgresql_admin_username" -h "$postgres_ip" -p $db_port "${db_name}_temp"

# Remove the dump file
echo -e "\n# ========================================================"
echo "# 8. Removing the dump file..."
echo -e "# ========================================================\n"
rm "${db_name_stripped}.dump"



# Unset the PGPASSWORD environment variable
unset PGPASSWORD