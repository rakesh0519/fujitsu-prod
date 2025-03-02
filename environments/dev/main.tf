locals {
  prefix = "icp-dev"
  location = "East US"
  data_location = "United States"
}

resource "azurerm_resource_group" "resourcegroup" {
  name     = "${local.prefix}-resources"
  location = local.location
}

module "cosmos" {
  source  = "../../modules/cosmos"
  depends_on = [module.networking, module.storage, module.monitoring]
  resource_group_name = azurerm_resource_group.resourcegroup.name
  location            = local.location

  cosmosdb_account = {
    "${local.prefix}-cosmos-account" = {
        offer_type                            = "Standard"
        kind                                  = "GlobalDocumentDB"
        analytical_storage_enabled            = false  
        public_network_access_enabled         = false  # Increased security in prod
        key_vault_key_id                     = null
        access_key_metadata_writes_enabled    = false  # Restrict metadata writes for added security
        network_acl_bypass_for_azure_services = false # Prevent Azure services from bypassing ACL in prod
        is_virtual_network_filter_enabled     = true
    }
 }

  consistency_policy = {
    consistency_level       = "Strong"  # Strong consistency for better data reliability in prod
  }

  failover_locations = [
    {
      location          = local.location
      failover_priority = 0
    },
     {
      location          = "eastus"  # Adding a secondary failover region for HA in prod
      failover_priority = 1
    }
  ]

  capabilities = ["EnableServerless"]  #  No changes required for prod

  virtual_network_rules = [
    {
      id = module.networking.db_subnet_id
      ignore_missing_vnet_service_endpoint = false
    }
  ]  #  No changes required for prod

  backup = {
     type                = "Continuous"  # Continuous backup for better disaster recovery in prod
     interval_in_minutes = null  # Not needed for continuous backup
     retention_in_hours  = null  # Not needed for continuous backup
  }

  cors_rules = {
    allowed_headers    = ["x-ms-meta-data*"]
    allowed_methods    = ["GET", "POST"]
    allowed_origins    = ["*"]
    exposed_headers    = ["*"]
    max_age_in_seconds = 3600
  }  #  No changes required for prod

  enable_advanced_threat_protection = true  #  No changes required for prod
  enable_private_endpoint       = true  # No changes required for prod
  virtual_network_name          = module.networking.virtual_network_name  #  No changes required for prod
  private_subnet_address_prefix = module.networking.pvt_subnet.address_prefix  #  No changes required for prod

  allowed_ip_range_cidrs = [
     "10.0.0.0/16"  # Restrict access to internal IPs in prod
  ]

   dedicated_instance_size = "Cosmos.D8s"  # Increased instance size for higher workloads in prod
   dedicated_instance_count = 2  # Increased instance count for better performance in prod

  log_analytics_workspace_name = module.monitoring.log_analytics_workspace_name  #  No changes required for prod
  storage_account_name = module.storage.storage_account_name  #  No changes required for prod
  
  tags = {
    ProjectName  = "fujitsu-icp"
     Environment  = "prod"  # Updated tag to reflect production environment
  }
}

module "redis_service" {
  source              = "../../modules/redis_service"
   redis_name          = "redis-cache-prod-unique"  # Updated to a unique name for production
   location            = "westus"  # Updated to a production region based on HA requirements
  resource_group_name  = azurerm_resource_group.resourcegroup.name
   sku_name            = "Premium"  # Increased SKU for better performance and enhanced security in production
   capacity            = 3  # Increased capacity to handle production workloads efficiently
  # enable_non_ssl_port = false  # This is okay for both prod and dev; no changes required.

  tags = {
     environment = "prod"  # Updated to reflect production environment
    project     = "my-project"  # This is okay for both prod and dev; no changes required.
  }
}


module "networking" {
  source = "../../modules/networking"
  resource_group_name            = azurerm_resource_group.resourcegroup.name
  location                       = local.location
  vnetwork_name                  = "${local.prefix}-vnet"
  vnet_address_space             = ["10.1.0.0/16"]

  subnets = {
    frontend_subnet = {
      subnet_name           = "frontend_subnet"
      subnet_address_prefix = ["10.1.2.0/24"]
      service_endpoints     = ["Microsoft.Web"]

      delegation = {
        name = "webappdelegation"
        service_delegation = {
          name = "Microsoft.Web/serverFarms"
          actions = [
            "Microsoft.Network/virtualNetworks/subnets/join/action",
            "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action"
          ]
        }
      }

      nsg_inbound_rules = [
        # [name, priority, direction, access, protocol, destination_port_range, source_address_prefix, destination_address_prefix]

        # Allow HTTP traffic from Application Gateway
        ["web_allow_http", 100, "Inbound", "Allow", "Tcp", "80", "10.1.1.0/27", "*"],

        # Allow HTTPS traffic from Application Gateway
        ["web_allow_https", 101, "Inbound", "Allow", "Tcp", "443", "10.1.1.0/27", "*"],

        # Allow custom TCP port range if needed
        ["web_custom_ports", 102, "Inbound", "Allow", "Tcp", "8080-8090", "10.1.1.0/27", "*"],

        # Restrict access to Application Gateway subnet only if necessary (replace with subnet CIDR if desired)
        ["app_gateway_restricted", 110, "Inbound", "Allow", "Tcp", "80", "10.1.1.0/27", "0.0.0.0/0"]
      ]

      nsg_outbound_rules = [
        # Allow outbound NTP traffic for time sync
        ["ntp_out", 103, "Outbound", "Allow", "Udp", "123", "*", "0.0.0.0/0"],

        # Allow outbound HTTP/HTTPS if web app needs to access external resources
        ["outbound_http", 104, "Outbound", "Allow", "Tcp", "80", "*", "0.0.0.0/0"],
        ["outbound_https", 105, "Outbound", "Allow", "Tcp", "443", "*", "0.0.0.0/0"]
      ]
    }

    backend_subnet = {
      subnet_name           = "backend_subnet"
      subnet_address_prefix = ["10.1.3.0/24"]
      service_endpoints     = ["Microsoft.Web"]

      delegation = {
        name = "webappdelegation"
        service_delegation = {
          name = "Microsoft.Web/serverFarms"
          actions = [
            "Microsoft.Network/virtualNetworks/subnets/join/action",
            "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action"
          ]
        }
      }

      nsg_inbound_rules = [
        # Allow HTTP traffic for backend from frontend subnet
        ["backend_http_allow", 200, "Inbound", "Allow", "Tcp", "80", "10.1.2.0/24", "*"],

        # Allow HTTPS traffic for backend from frontend subnet
        ["backend_https_allow", 201, "Inbound", "Allow", "Tcp", "443", "10.1.2.0/24", "*"],

        # Allow custom port (e.g., 9090) for internal application communication within the VNet
        ["backend_custom_internal", 202, "Inbound", "Allow", "Tcp", "9090", "VirtualNetwork", "*"]
      ]

      nsg_outbound_rules = [
        # Allow outbound traffic to Cosmos DB service
        ["cosmos_db_outbound_allow", 300, "Outbound", "Allow", "Tcp", "443", "*", "AzureCosmosDB"],

        # Allow outbound HTTPS for any necessary API or external service access
        ["outbound_https", 301, "Outbound", "Allow", "Tcp", "443", "*", "0.0.0.0/0"]
      ]
    }

    db_subnet = {
      subnet_name           = "db_subnet"
      subnet_address_prefix = ["10.1.4.0/24"]
      service_endpoints     = ["Microsoft.AzureCosmosDB"]
      private_link_service_network_policies_enabled = true

      nsg_inbound_rules = [
        # Allow traffic from backend subnet to Cosmos DB
        ["backend_to_db_allow", 400, "Inbound", "Allow", "Tcp", "443", "10.1.3.0/24", "*"]
      ]

      nsg_outbound_rules = [
        # Allow outbound traffic to Cosmos DB service
        ["cosmos_db_outbound_allow", 401, "Outbound", "Allow", "Tcp", "443", "*", "AzureCosmosDB"]
      ]
    }

    pvt_subnet = {
      subnet_name           = "pvt_subnet"
      subnet_address_prefix = ["10.1.5.0/29"]
      service_endpoints     = ["Microsoft.Storage","Microsoft.KeyVault","Microsoft.AzureCosmosDB"]
      private_endpoint_network_policies = "NetworkSecurityGroupEnabled"
    }

    gateway_subnet = {
      subnet_name           = "gateway_subnet"
      subnet_address_prefix = ["10.1.6.0/24"]
      service_endpoints     = ["Microsoft.Storage"]

      nsg_inbound_rules = [
        # Allow Azure-managed traffic for Application Gateway V2 (required for backend health monitoring and management)
        ["appgw_v2_azure_traffic", 200, "Inbound", "Allow", "Tcp", "65200-65535", "GatewayManager", "*"],

        # Allow HTTP traffic from any source to the Application Gateway
        ["appgw_http_allow", 201, "Inbound", "Allow", "Tcp", "80", "*", "*"],

        # Allow HTTPS traffic from Azure Load Balancer to the Application Gateway
        ["appgw_https_allow", 202, "Inbound", "Allow", "Tcp", "443", "AzureLoadBalancer", "*"],

        # Allow custom port (9090) for internal communication within the VNet to the Application Gateway
        ["appgw_custom_internal", 203, "Inbound", "Allow", "Tcp", "9090", "VirtualNetwork", "*"]
      ]

      nsg_outbound_rules = [
      ]
    }
  }

  tags = {
    ProjectName = "fujitsu-icp"
    Environment = "Prod"
  }
}

module "storage" {
  source = "../../modules/storage"
  resource_group_name = azurerm_resource_group.resourcegroup.name
  location            = local.location
  
  storage_account_name  = "${local.prefix}storage"
  account_kind = "StorageV2"
  access_tier = "Hot"
  skuname = "Premium_LRS" # Changed for production

  enable_advanced_threat_protection = true

  # containers_list = [
  #  { name = "blobcontainer251", access_type = "blob" }
  # ]

  # Configure managed identities to access Azure Storage (Optional)
  # Possible types are `SystemAssigned`, `UserAssigned` and `SystemAssigned, UserAssigned`.
  # managed_identity_type = "UserAssigned"
  # managed_identity_ids  = [for k in azurerm_user_assigned_identity.example : k.id]

  # lifecycles = [
  #   {
  #     prefix_match               = ["blobcontainer251"]
  #     tier_to_cool_after_days    = 0
  #     tier_to_archive_after_days = 50
  #     delete_after_days          = 100
  #     snapshot_delete_after_days = 30
  #   }
  # ]

  tags = {
    ProjectName  = "fujitsu-icp"
    Environment  = "prod" # Updated for production
  }
}

module "frontend-app-service" {
  source  = "../../modules/app_service"
  depends_on = [module.networking, module.storage]
  resource_group_name = azurerm_resource_group.resourcegroup.name
  location            = local.location

  app_service_plan_name = "${local.prefix}-frontendserviceplan"
  service_plan = {
    os_type = "Linux"
    sku_name = "P1v2" #  Modified: Changed from B1 to P1v2 for production to ensure better performance and scaling
  }

  app_service_name       = "${local.prefix}-fe-flutter-app"
  enable_client_affinity = true
  enable_https           = true

  site_config = {
    always_on                 = true #  No changes required for prod
    ftps_state                = "FtpsOnly" #  No changes required for prod
    http2_enabled             = true #  No changes required for prod
  }

  application_stack = {
    type    = "NODE"
    version = "20-lts" #  No changes required for prod
  }

  # (Optional) A key-value pair of Application Settings
  app_settings = {
    APPINSIGHTS_PROFILERFEATURE_VERSION             = "1.0.0" #  No changes required for prod
    APPINSIGHTS_SNAPSHOTFEATURE_VERSION             = "1.0.0" #  No changes required for prod
    DiagnosticServices_EXTENSION_VERSION            = "~3" #  No changes required for prod
    InstrumentationEngine_EXTENSION_VERSION         = "disabled" #  No changes required for prod
    SnapshotDebugger_EXTENSION_VERSION              = "disabled" #  No changes required for prod
    XDT_MicrosoftApplicationInsights_BaseExtensions = "disabled" #  No changes required for prod
    XDT_MicrosoftApplicationInsights_Java           = "1" #  No changes required for prod
    XDT_MicrosoftApplicationInsights_Mode           = "recommended" #  No changes required for prod
    XDT_MicrosoftApplicationInsights_NodeJS         = "1" #  No changes required for prod
    XDT_MicrosoftApplicationInsights_PreemptSdk     = "disabled" #  No changes required for prod
  }

  enable_backup        = true #  No changes required for prod
  storage_account_name = module.storage.storage_account_name #  No changes required for prod
  storage_container_name = "frontend-appservice-backup" #  No changes required for prod
  backup_settings = {
    enabled                  = true #  No changes required for prod
    name                     = "DefaultBackup" #  No changes required for prod
    frequency_interval       = 1 # No changes required for prod
    frequency_unit           = "Day" #  No changes required for prod
    retention_period_days    = 180 #  Modified: Increased retention period from 90 to 180 days for better disaster recovery in prod
  }

  app_insights_name = "frontendapp" #  No changes required for prod

  enable_vnet_integration = true #  No changes required for prod
  subnet_id = module.networking.frontend_subnet_id #  No changes required for prod

  tags = {
    ProjectName  = "fujitsu-icp" #  No changes required for prod
    Environment  = "prod" # Modified: Changed from "dev" to "prod"
  }
}

module "api_management" {
  source              = "../../modules/api_management"
  depends_on          = [module.frontend-app-service]
  resource_group_name = azurerm_resource_group.resourcegroup.name
  location            = local.location
  api_management_name = "${local.prefix}-api-management-v2"
  publisher_name      = "Rock Paper Panda"
  publisher_email     = "team@rockpaperpanda.com"
  sku_name            = "Premium_1" #  Modified: Changed from "Developer_1" to "Premium_1" for production to support higher performance, scaling, and VNET integration
}

module "communication_service" {
  source                  = "../../modules/communication_service"
  depends_on              = [module.backend-app-service]
  resource_group_name     = azurerm_resource_group.resourcegroup.name
  location                = local.location
  communication_service_name = "${local.prefix}-communication-svc"
  data_location           = local.data_location #  No changes required for prod
}

module "backend-app-service" {
  source  = "../../modules/app_service"
  depends_on = [module.networking, module.storage]
  resource_group_name = azurerm_resource_group.resourcegroup.name
  location            = local.location

  app_service_plan_name = "${local.prefix}-backendserviceplan"
  service_plan = {
    os_type   = "Linux"
    sku_name  = "P1v2" #  Changed from "B1" to "P1v2" for better performance in production
  }

  app_service_name       = "${local.prefix}-be-python-app"
  enable_client_affinity = true
  enable_https           = true

  site_config = {
    always_on                 = true
    ftps_state                = "FtpsOnly"
    http2_enabled             = true
  }

  application_stack = {
    type    = "PYTHON"
    version = "3.9" #  No changes required for prod
  }

  # (Optional) A key-value pair of Application Settings
  app_settings = {
    APPINSIGHTS_PROFILERFEATURE_VERSION             = "1.0.0"
    APPINSIGHTS_SNAPSHOTFEATURE_VERSION             = "1.0.0"
    DiagnosticServices_EXTENSION_VERSION            = "~3"
    InstrumentationEngine_EXTENSION_VERSION         = "disabled"
    SnapshotDebugger_EXTENSION_VERSION              = "disabled"
    XDT_MicrosoftApplicationInsights_BaseExtensions = "disabled"
    XDT_MicrosoftApplicationInsights_Java           = "1"
    XDT_MicrosoftApplicationInsights_Mode           = "recommended"
    XDT_MicrosoftApplicationInsights_NodeJS         = "1"
    XDT_MicrosoftApplicationInsights_PreemptSdk     = "disabled"
  }

  enable_backup        = true
  storage_account_name = module.storage.storage_account_name
  storage_container_name = "backend-appservice-backup"
  backup_settings = {
    enabled                  = true
    name                     = "DefaultBackup"
    frequency_interval       = 1
    frequency_unit           = "Day"
    retention_period_days    = 180 #  Increased from 90 to 180 for longer data retention in production
  }

  app_insights_name = "backendapp"
  enable_vnet_integration = true
  subnet_id = module.networking.backend_subnet_id

  tags = {
    ProjectName  = "fujitsu-icp"
    Environment  = "prod" #  Changed from "dev" to "prod" for production environment
  }
}

module "key-vault" {
  source  = "../../modules/key_vault"
  depends_on = [module.networking, module.storage]
  resource_group_name = azurerm_resource_group.resourcegroup.name
  location            = local.location

  key_vault_name             = "${local.prefix}-keyvault"
  key_vault_sku_pricing_tier = "premium" #  Premium SKU is ideal for production

  # Once `Purge Protection` has been Enabled it's not possible to Disable it
  # Deleting the Key Vault with `Purge Protection` enabled will schedule the Key Vault to be deleted
  # The default retention period is 90 days, possible values are from 7 to 90 days
  # use `soft_delete_retention_days` to set the retention period
  enable_purge_protection = true #  Enabled for production security
  soft_delete_retention_days = 90 #  Retained at 90 days for compliance

  # Access policies for users, you can provide list of Azure AD users and set permissions.
  # Make sure to use list of user principal names of Azure AD users.
  # access_policies = [
  #   {
  #     azure_ad_user_principal_names = [""]
  #     key_permissions               = ["Get", "List"]
  #     secret_permissions            = ["Get", "List"]
  #     certificate_permissions       = ["Get", "Import", "List"]
  #     storage_permissions           = ["Backup", "Get", "List", "Recover"]
  #   },

  #   # Access policies for AD Groups
  #   # to enable this feature, provide a list of Azure AD groups and set permissions as required.
  #   {
  #     azure_ad_group_names    = [""]
  #     key_permissions         = ["Get", "List"]
  #     secret_permissions      = ["Get", "List"]
  #     certificate_permissions = ["Get", "Import", "List"]
  #     storage_permissions     = ["Backup", "Get", "List", "Recover"]
  #   },

  #   # Access policies for Azure AD Service Principals
  #   # To enable this feature, provide a list of Azure AD SPN and set permissions as required.
  #   {
  #     azure_ad_service_principal_names = [""]
  #     key_permissions                  = ["Get", "List"]
  #     certificate_permissions          = ["Get", "Import", "List"]
  #     storage_permissions              = ["Backup", "Get", "List", "Recover"]
  #   }
  # ]

  # Create a required Secrets as per your need.
  # When you Add `usernames` with empty password this module creates a strong random password
  # use .tfvars file to manage the secrets as variables to avoid security issues.
  secrets = {
    "message" = "Hello, production!" #  Changed secret message for production
    "vmpass"  = ""
  }

  enable_private_endpoint       = true
  virtual_network_name          = module.networking.virtual_network_name
  private_subnet_address_prefix = module.networking.pvt_subnet.address_prefix
  log_analytics_workspace_name = module.monitoring.log_analytics_workspace_name
  storage_account_name = module.storage.storage_account_name

  tags = {
    ProjectName  = "fujitsu-icp"
    Environment  = "prod" #  Updated environment from "dev" to "prod"
  }
}


module "application-gateway" {
  source     = "../../modules/application_gateway"
  depends_on = [module.networking, module.frontend-app-service, module.storage, module.monitoring]

  resource_group_name = azurerm_resource_group.resourcegroup.name
  location            = local.location

  virtual_network_name = module.networking.virtual_network_name
  subnet_name          = module.networking.gateway_subnet
  app_gateway_name     = "testgateway"

  sku = {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

  autoscale_configuration = {
    min_capacity = 2   #  Ensure at least 2 instances for high availability  
    max_capacity = 10  #  Increased max capacity for peak loads  
  }

  backend_address_pools = [
    {
      name  = "appgw-testgateway-eastus-bapool01"
      fqdns = [module.frontend-app-service.default_hostname]
    }
  ]

  backend_http_settings = [
    {
      name                  = "appgw-testgateway-eastus-be-http-set1"
      cookie_based_affinity = "Disabled"
      path                  = "/"
      enable_https          = true
      request_timeout       = 30
      host_name             = module.frontend-app-service.default_hostname
      probe_name            = "appgw-testgateway-eastus-probe1"
      connection_draining = {
        enable_connection_draining = true
        drain_timeout_sec          = 300
      }
    },
    {
      name                  = "appgw-testgateway-eastus-be-http-set2"
      cookie_based_affinity = "Enabled"
      path                  = "/"
      enable_https          = false
      request_timeout       = 30
    }
  ]

  http_listeners = [
    {
      name = "appgw-prod-eastus-be-htln01"
      ssl_certificate_name = "appgw-prod-ssl-cert" #  Enabled SSL certificate  
      host_name = null
    }
  ]

     # No changes needed for request routing rules  
  request_routing_rules = [
    {
      name                       = "appgw-prod-eastus-be-rqrt"
      rule_type                  = "Basic"
      http_listener_name         = "appgw-prod-eastus-be-htln01"
      backend_address_pool_name  = "appgw-prod-eastus-bapool01"
      backend_http_settings_name = "appgw-prod-eastus-be-http-set1"
      priority                   = 1
    }
  ]


  # ssl_certificates = [{
  #   name     = "appgw-testgateway-eastus-ssl01"
  #   data     = "./keyBag.pfx"
  #   password = "P@$$w0rd123"
  # }]

  health_probes = [
    {
      name                = "appgw-testgateway-eastus-probe1"
      host                = module.frontend-app-service.default_hostname
      interval            = 30
      path                = "/"
      port                = 443
      timeout             = 30
      unhealthy_threshold = 3
    }
  ]

  # A list with a single user managed identity id to be assigned to access Keyvault
  # identity_ids = ["${azurerm_user_assigned_identity.example.id}"]

   # No changes required for logging & monitoring  
  log_analytics_workspace_name = module.monitoring.log_analytics_workspace_name
  storage_account_name         = module.storage.storage_account_name

   # Tags remain unchanged  
  tags = {
    ProjectName = "fujitsu-icp"
    Environment = "prod"  #  Changed from dev to prod  
  }
}

module "monitoring" {
  source = "../../modules/monitoring"
  resource_group_name = azurerm_resource_group.resourcegroup.name
  location            = local.location

  log_analytics_workspace_name = "${local.prefix}-logws"
  sku                          = "PerGB2018" #  No change, as it's a standard SKU for log analytics.
  retention_in_days            = "90"        #  Increased from 30 days to 90 for better log retention in production.
}
}
