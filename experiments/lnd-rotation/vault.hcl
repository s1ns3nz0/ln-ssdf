ui = false
disable_mlock = true

storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address = "0.0.0.0:8201"
  tls_disable = 1
}

api_addr = "http://ln-ssdf-e3-vault:8201"
cluster_addr = "http://ln-ssdf-e3-vault:8202"
