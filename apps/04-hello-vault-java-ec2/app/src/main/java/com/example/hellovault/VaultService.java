package com.example.hellovault;

import com.bettercloud.vault.Vault;
import com.bettercloud.vault.VaultConfig;
import com.bettercloud.vault.VaultException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.services.sts.StsClient;
import software.amazon.awssdk.services.sts.auth.StsAssumeRoleCredentialsProvider;

import java.util.Map;

/**
 * Authenticates to Vault using AWS IAM auth, then reads a KV v2 secret.
 * A new token is obtained on each call (suitable for demo; production code
 * should cache and renew tokens).
 */
@Service
public class VaultService {

    @Value("${vault.addr}")
    private String vaultAddr;

    @Value("${vault.namespace:}")
    private String vaultNamespace;

    @Value("${vault.role}")
    private String vaultRole;

    @Value("${vault.mount-point:secret}")
    private String mountPoint;

    @Value("${vault.secret-path:config}")
    private String secretPath;

    public Map<String, String> readSecret() throws VaultException {
        VaultConfig config = new VaultConfig()
                .address(vaultAddr)
                .nameSpace(vaultNamespace.isBlank() ? null : vaultNamespace)
                .build();

        Vault vault = new Vault(config);

        // AWS IAM auth — vault-java-driver builds the signed STS request
        String token = vault.auth()
                .loginByAwsIam(vaultRole, null, null, null, null)
                .getAuthClientToken();

        VaultConfig authedConfig = new VaultConfig()
                .address(vaultAddr)
                .nameSpace(vaultNamespace.isBlank() ? null : vaultNamespace)
                .token(token)
                .build();

        Vault authedVault = new Vault(authedConfig);
        Map<String, String> data = authedVault.logical()
                .read(mountPoint + "/data/" + secretPath)
                .getData();

        return data;
    }
}
