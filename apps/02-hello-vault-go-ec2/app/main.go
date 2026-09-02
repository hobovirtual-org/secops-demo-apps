// Hello Vault — Go
// Authenticates to HashiCorp Vault using AWS IAM auth, then reads a KV v2 secret.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"

	vault "github.com/hashicorp/vault/api"
	vaultaws "github.com/hashicorp/vault/api/auth/aws"
)

var (
	vaultAddr  = mustEnv("VAULT_ADDR")
	vaultNS    = os.Getenv("VAULT_NAMESPACE")
	vaultRole  = mustEnv("VAULT_ROLE")
	secretPath = os.Getenv("SECRET_PATH")
	mountPoint = os.Getenv("MOUNT_POINT")
)

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("required environment variable %s is not set", key)
	}
	return v
}

func newVaultClient() (*vault.Client, error) {
	cfg := vault.DefaultConfig()
	cfg.Address = vaultAddr

	client, err := vault.NewClient(cfg)
	if err != nil {
		return nil, err
	}
	if vaultNS != "" {
		client.SetNamespace(vaultNS)
	}

	awsAuth, err := vaultaws.NewAWSAuth(vaultaws.WithRole(vaultRole))
	if err != nil {
		return nil, err
	}
	if _, err = client.Auth().Login(nil, awsAuth); err != nil {
		return nil, err
	}
	return client, nil
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
	client, err := newVaultClient()
	if err != nil {
		log.Printf("ERROR vault auth: %v", err)
		http.Error(w, "vault authentication failed", http.StatusInternalServerError)
		return
	}

	secret, err := client.KVv2(mountPoint).Get(r.Context(), secretPath)
	if err != nil {
		log.Printf("ERROR reading secret: %v", err)
		http.Error(w, "secret read failed", http.StatusInternalServerError)
		return
	}

	resp := map[string]string{
		"status":      "ok",
		"greeting":    secret.Data["greeting"].(string),
		"db_username": secret.Data["db_username"].(string),
		// Never return db_password
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"healthy"}`))
}

func main() {
	addr := "127.0.0.1:" + os.Getenv("PORT")
	if addr == "127.0.0.1:" {
		addr = "127.0.0.1:8080"
	}
	http.HandleFunc("/", indexHandler)
	http.HandleFunc("/health", healthHandler)
	log.Printf("Listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}
