locals {
  access_policies = [
    for p in var.access_policies : merge({
      azure_ad_group_names             = []
      object_ids                       = []
      azure_ad_user_principal_names    = []
      certificate_permissions          = []
      key_permissions                  = []
      secret_permissions               = []
      storage_permissions              = []
      azure_ad_service_principal_names = []
    }, p)
  ]

  azure_ad_group_names             = distinct(flatten(local.access_policies[*].azure_ad_group_names))
  azure_ad_user_principal_names    = distinct(flatten(local.access_policies[*].azure_ad_user_principal_names))
  azure_ad_service_principal_names = distinct(flatten(local.access_policies[*].azure_ad_service_principal_names))

  group_object_ids = { for g in data.azuread_group.adgrp : lower(g.display_name) => replace(g.id, "//groups//", "") }
  user_object_ids  = { for u in data.azuread_user.adusr : lower(u.user_principal_name) => replace(u.id, "//users//", "") }
  spn_object_ids   = { for s in data.azuread_service_principal.adspn : lower(s.display_name) => replace(s.id, "//servicePrincipals//", "") }

  flattened_access_policies = concat(
    flatten([
      for p in local.access_policies : flatten([
        for i in p.object_ids : {
          object_id               = i
          certificate_permissions = p.certificate_permissions
          key_permissions         = p.key_permissions
          secret_permissions      = p.secret_permissions
          storage_permissions     = p.storage_permissions
        }
      ])
    ]),
    flatten([
      for p in local.access_policies : flatten([
        for n in p.azure_ad_group_names : {
          object_id               = local.group_object_ids[lower(n)]
          certificate_permissions = p.certificate_permissions
          key_permissions         = p.key_permissions
          secret_permissions      = p.secret_permissions
          storage_permissions     = p.storage_permissions
        }
      ])
    ]),
    flatten([
      for p in local.access_policies : flatten([
        for n in p.azure_ad_user_principal_names : {
          object_id               = local.user_object_ids[lower(n)]
          certificate_permissions = p.certificate_permissions
          key_permissions         = p.key_permissions
          secret_permissions      = p.secret_permissions
          storage_permissions     = p.storage_permissions
        }
      ])
    ]),
    flatten([
      for p in local.access_policies : flatten([
        for n in p.azure_ad_service_principal_names : {
          object_id               = local.spn_object_ids[lower(n)]
          certificate_permissions = p.certificate_permissions
          key_permissions         = p.key_permissions
          secret_permissions      = p.secret_permissions
          storage_permissions     = p.storage_permissions
        }
      ])
    ])
  )

  grouped_access_policies = { for p in local.flattened_access_policies : p.object_id => p... }

  combined_access_policies = [
    for k, v in local.grouped_access_policies : {
      object_id               = k
      certificate_permissions = distinct(flatten(v[*].certificate_permissions))
      key_permissions         = distinct(flatten(v[*].key_permissions))
      secret_permissions      = distinct(flatten(v[*].secret_permissions))
      storage_permissions     = distinct(flatten(v[*].storage_permissions))
    }
  ]

  service_principal_object_id = data.azurerm_client_config.current.object_id

  self_permissions = {
    object_id               = local.service_principal_object_id
    tenant_id               = data.azurerm_client_config.current.tenant_id
    key_permissions         = ["Create", "Delete", "Get", "Backup", "Decrypt", "Encrypt", "Import", "List", "Purge", "Recover", "Restore", "Sign", "Update", "Verify"]
    secret_permissions      = ["Get", "List", "Set", "Delete", "Recover", "Backup", "Restore", "Purge"]
    certificate_permissions = ["DeleteIssuers", "GetIssuers", "ListIssuers", "ManageContacts", "ManageIssuers", "SetIssuers"]
    storage_permissions     = ["DeleteSAS", "GetSAS", "ListSAS", "RegenerateKey", "SetSAS"]
  }
}

#-------------------------------------------------------------
# Log Analytics Workspace 
#-------------------------------------------------------------
data "azurerm_log_analytics_workspace" "logws" {
  name                = var.log_analytics_workspace_name
  resource_group_name = var.resource_group_name
}

data "azurerm_storage_account" "storeacc" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
}

data "azuread_group" "adgrp" {
  count        = length(local.azure_ad_group_names)
  display_name = local.azure_ad_group_names[count.index]
}

data "azuread_user" "adusr" {
  count               = length(local.azure_ad_user_principal_names)
  user_principal_name = local.azure_ad_user_principal_names[count.index]
}

data "azuread_service_principal" "adspn" {
  count        = length(local.azure_ad_service_principal_names)
  display_name = local.azure_ad_service_principal_names[count.index]
}

data "azurerm_client_config" "current" {}

#-------------------------------------------------
# Keyvault Creation
#-------------------------------------------------
resource "random_integer" "intg" {
  min = 500
  max = 50000
  keepers = {
    name = var.resource_group_name
  }
}

resource "azurerm_key_vault" "main" {
  name                            = format("%s-%s", lower("${var.key_vault_name}"), random_integer.intg.result)
  location                        = var.location
  resource_group_name             = var.resource_group_name
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  sku_name                        = var.key_vault_sku_pricing_tier
  enabled_for_deployment          = var.enabled_for_deployment
  enabled_for_disk_encryption     = var.enabled_for_disk_encryption
  enabled_for_template_deployment = var.enabled_for_template_deployment
  soft_delete_retention_days      = var.soft_delete_retention_days
  enable_rbac_authorization       = var.enable_rbac_authorization
  purge_protection_enabled        = var.enable_purge_protection
  tags                            = merge({ "ResourceName" = lower("kv-${var.key_vault_name}") }, var.tags, )

  dynamic "network_acls" {
    for_each = var.network_acls != null ? [true] : []
    content {
      bypass                     = var.network_acls.bypass
      default_action             = var.network_acls.default_action
      ip_rules                   = var.network_acls.ip_rules
      virtual_network_subnet_ids = var.network_acls.virtual_network_subnet_ids
    }
  }

  dynamic "access_policy" {
    for_each = local.combined_access_policies
    content {
      tenant_id               = data.azurerm_client_config.current.tenant_id
      object_id               = access_policy.value.object_id
      certificate_permissions = access_policy.value.certificate_permissions
      key_permissions         = access_policy.value.key_permissions
      secret_permissions      = access_policy.value.secret_permissions
      storage_permissions     = access_policy.value.storage_permissions
    }
  }

  dynamic "access_policy" {
    for_each = local.service_principal_object_id != "" ? [local.self_permissions] : []
    content {
      tenant_id               = data.azurerm_client_config.current.tenant_id
      object_id               = access_policy.value.object_id
      certificate_permissions = access_policy.value.certificate_permissions
      key_permissions         = access_policy.value.key_permissions
      secret_permissions      = access_policy.value.secret_permissions
      storage_permissions     = access_policy.value.storage_permissions
    }
  }

  dynamic "contact" {
    for_each = var.certificate_contacts
    content {
      email = contact.value.email
      name  = contact.value.name
      phone = contact.value.phone
    }
  }

lifecycle {
    ignore_changes = [
      tags,
      network_acls,
      sku_name,
      soft_delete_retention_days,
      purge_protection_enabled
    ]
  }
}

#-----------------------------------------------------------------------------------
# Keyvault Secret - Random password Creation if value is empty - Default is "false"
#-----------------------------------------------------------------------------------
resource "random_password" "passwd" {
  for_each    = { for k, v in var.secrets : k => v if v == "" }
  length      = var.random_password_length
  min_upper   = 4
  min_lower   = 2
  min_numeric = 4
  min_special = 4

  keepers = {
    name = each.key
  }
}

resource "azurerm_key_vault_secret" "keys" {
  for_each     = var.secrets
  name         = each.key
  value        = each.value != "" ? each.value : random_password.passwd[each.key].result
  key_vault_id = azurerm_key_vault.main.id

  lifecycle {
    ignore_changes = [
      tags,
      value,
    ]
  }
}

#---------------------------------------------------------
# Private Link for Key Vault
#---------------------------------------------------------
data "azurerm_virtual_network" "vnet" {
  count               = var.enable_private_endpoint ? 1 : 0
  name                = var.virtual_network_name
  resource_group_name = var.resource_group_name
}

data "azurerm_subnet" "snet" {
  count                = var.enable_private_endpoint ? 1 : 0
  name                 = "pvt_subnet"
  virtual_network_name = data.azurerm_virtual_network.vnet.0.name
  resource_group_name  = var.resource_group_name
}

resource "azurerm_private_endpoint" "pep2" {
  count               = var.enable_private_endpoint ? 1 : 0
  name                = format("%s-private-endpoint", var.key_vault_name)
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.existing_subnet_id == null ? data.azurerm_subnet.snet.0.id : var.existing_subnet_id
  tags                = merge({ "Name" = format("%s-private-endpoint", var.key_vault_name) }, var.tags, )

  private_service_connection {
    name                           = "keyvault-privatelink"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
  }

  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}

data "azurerm_private_endpoint_connection" "private-ip2" {
  count               = var.enable_private_endpoint ? 1 : 0
  name                = azurerm_private_endpoint.pep2.0.name
  resource_group_name = var.resource_group_name
  depends_on          = [azurerm_key_vault.main]
}

resource "azurerm_private_dns_zone" "dnszone2" {
  count               = var.existing_private_dns_zone == null && var.enable_private_endpoint ? 1 : 0
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group_name
  tags                = merge({ "Name" = format("%s", "KeyVault-Private-DNS-Zone") }, var.tags, )
}

resource "azurerm_private_dns_zone_virtual_network_link" "vent-link2" {
  count                 = var.enable_private_endpoint ? 1 : 0
  name                  = "vnet-private-zone-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = var.existing_private_dns_zone == null ? azurerm_private_dns_zone.dnszone2.0.name : var.existing_private_dns_zone
  virtual_network_id    = var.existing_vnet_id == null ? data.azurerm_virtual_network.vnet.0.id : var.existing_vnet_id
  registration_enabled  = true
  tags                  = merge({ "Name" = format("%s", "vnet-private-zone-link") }, var.tags, )

  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}

resource "azurerm_private_dns_a_record" "arecord2" {
  count               = var.enable_private_endpoint ? 1 : 0
  name                = azurerm_key_vault.main.name
  zone_name           = var.existing_private_dns_zone == null ? azurerm_private_dns_zone.dnszone2.0.name : var.existing_private_dns_zone
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [data.azurerm_private_endpoint_connection.private-ip2.0.private_service_connection.0.private_ip_address]
}

#---------------------------------------------------
# azurerm monitoring diagnostics - KeyVault
#---------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "diag" {
  name                       = lower(format("%s-diag", azurerm_key_vault.main.name))
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.logws.id
  storage_account_id         = data.azurerm_storage_account.storeacc.id

  dynamic "enabled_log" {
    for_each = var.kv_diag_logs
    content {
      category = enabled_log.value
    }
  }

  metric {
    category = "AllMetrics"
    enabled = true
  }

  lifecycle {
    ignore_changes = [enabled_log, metric]
  }
}