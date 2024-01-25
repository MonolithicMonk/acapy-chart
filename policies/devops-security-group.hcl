
vault policy write security - << EOF

# ========= Auth Path =========

# Manage tokens for verification
path "auth/token/create" {
  capabilities = [ "create", "read", "update", "delete", "list", "sudo" ]
}

# Allow access so that one can create roles for kubernetes auth
path "auth/kubernetes/role/*" {
  capabilities = ["create", "update"]
}

# Allow write access so that kubernetes auth method can be configured
path "auth/kubernetes/config" {
  capabilities = ["create", "update"]
}

# a list of auth methods
path "sys/auth" {
  capabilities = ["read"]
}

# Enable kubernetes authentication
path "sys/auth/kubernetes" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
}

# View a list of secrets engines
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

path "sys/mounts*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

path "secret/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

# Password policy
path "sys/policies/password*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# ====== Policy path =======
path "sys/policies/acl*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# ====== Database path =======
# # config
path "database/config*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# # reset
path "database/reset*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# # rotate-root
path "database/rotate-root*" {
  capabilities = ["create", "read", "update"]
}

# # roles
path "database/roles*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "database/roles/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# # creds
path "database/creds*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# # static-roles
path "database/static-roles*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# # static-creds
path "database/static-creds*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# # rotate-creds
path "database/rotate-creds*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# # rotate-role
path "database/rotate-role*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Add -output-policy flag / option to a command to see needed policy permissions
# eg: vault auth enable -output-policy kubernetes

EOF
