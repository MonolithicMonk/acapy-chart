vault policy write client-read-db-credentials - << EOF
path "database/creds/admin" {
  capabilities = ["read"]
}
EOF
