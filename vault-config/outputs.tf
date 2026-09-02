output "jwt_role_names" {
  description = "Map of app name to Vault JWT role name. Use to verify role provisioning."
  value = {
    demo-app-01 = vault_jwt_auth_backend_role.demo_app_01.role_name
    demo-app-02 = vault_jwt_auth_backend_role.demo_app_02.role_name
    demo-app-03 = vault_jwt_auth_backend_role.demo_app_03.role_name
    demo-app-04 = vault_jwt_auth_backend_role.demo_app_04.role_name
    demo-app-05 = vault_jwt_auth_backend_role.demo_app_05.role_name
    demo-app-06 = vault_jwt_auth_backend_role.demo_app_06.role_name
    demo-app-07 = vault_jwt_auth_backend_role.demo_app_07.role_name
  }
}

output "vault_policy_names" {
  description = "Map of app name to Vault policy name provisioned for each app workspace."
  value = {
    demo-app-01 = vault_policy.demo_app_01.name
    demo-app-02 = vault_policy.demo_app_02.name
    demo-app-03 = vault_policy.demo_app_03.name
    demo-app-04 = vault_policy.demo_app_04.name
    demo-app-05 = vault_policy.demo_app_05.name
    demo-app-06 = vault_policy.demo_app_06.name
    demo-app-07 = vault_policy.demo_app_07.name
  }
}
