package com.example.hellovault;

import com.bettercloud.vault.VaultException;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
public class SecretController {

    private final VaultService vaultService;

    public SecretController(VaultService vaultService) {
        this.vaultService = vaultService;
    }

    @GetMapping("/")
    public ResponseEntity<Map<String, String>> index() {
        try {
            Map<String, String> data = vaultService.readSecret();
            return ResponseEntity.ok(Map.of(
                    "status",      "ok",
                    "greeting",    data.getOrDefault("greeting", ""),
                    "db_username", data.getOrDefault("db_username", "")
                    // Never return db_password
            ));
        } catch (VaultException e) {
            return ResponseEntity.internalServerError()
                    .body(Map.of("status", "error", "message", "internal error"));
        }
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "healthy");
    }
}
