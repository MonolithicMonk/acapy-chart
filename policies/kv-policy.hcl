
vault policy write kv - << EOF
# To be more restrictive, start the path at where the application data starts
# for example the acapy zone-1, should be secret/+/acapy/zone-1
# Write and manage secrets in key-value secrets engine
path "secret*" {
  capabilities = [ "create", "read", "update", "delete", "list", "patch" ]
}
path "secret/*" {
  capabilities = [ "create", "read", "update", "delete", "list", "patch" ]
}

# To enable secrets engines
path "sys/mounts/*" {
  capabilities = [ "create", "read", "update", "delete" ]
}

EOF