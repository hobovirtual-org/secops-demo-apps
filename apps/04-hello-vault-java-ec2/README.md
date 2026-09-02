# 04 — Hello Vault (Java Spring Boot + EC2)

**Spring Boot app on EC2 that authenticates to Vault via AWS IAM auth and reads a KV v2 secret using the vault-java-driver.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Java](https://img.shields.io/badge/Java-21-1F6FEB)
![Spring Boot](https://img.shields.io/badge/Spring%20Boot-3.4.5-2EA043)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-AWS%20IAM-2EA043)

## At a Glance

| | |
|---|---|
| **Language** | Java 21 + Spring Boot 3.4.5 |
| **Infrastructure** | EC2 (RHEL 9), VPC, IAM role |
| **Vault auth method** | AWS IAM |
| **Vault secret** | KV v2 |
| **HCP Terraform workspace** | `demo-app-04-hello-vault-java` |

## Quick Start

```bash
# Build the fat jar
cd app
mvn package -DskipTests

# Copy to EC2 (or let CI/CD handle it)
scp target/hello-vault-*.jar ec2-user@<public_ip>:/opt/hello-vault-java/hello-vault.jar
sudo systemctl start hello-vault-java

# Test
curl http://<public_ip>:8080/
```

## Local development

```bash
cd app
cp .env.example .env
export $(cat .env | xargs)
mvn spring-boot:run
```
