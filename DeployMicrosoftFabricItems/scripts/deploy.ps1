param(
    [string] $azureClientId,
    [string] $azureClientSecret,
    [string] $azureTenantId,
    [string] $workspaceId,
    [string] $environmentName = "Test",
    [string] $fabricCicdVersion,
    [string] $repositoryDirectory = "./workspace",
    [string] $includeConfig,
    [string] $configFilePath,
    [string] $itemsInScope
)

$ErrorActionPreference = "Stop"
$scriptsFolder = $PSScriptRoot

function Log([string]$level, [string]$message) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[$ts][$level] $message"
}

function FailTask($message) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Error "[$ts][ERROR] $message"
    exit 1
}

function Validate-Guid($value, $name) {
    if ([string]::IsNullOrWhiteSpace($value)) { return }
    if (-not ($value -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')) {
        FailTask "$name must be a valid GUID. Value: $value"
    }
}

function Validate-Path($path, $name) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    # Prevent path traversal and invalid characters
    if ($path -match '\.\.|[<>"|?*]') {
        FailTask "$name contains invalid characters or path traversal pattern"
    }
}

function Validate-ItemsInScope($items) {
    if ([string]::IsNullOrWhiteSpace($items)) { return }
    # Allow only alphanumeric, comma, space, underscore, dash, dot
    if ($items -notmatch '^[a-zA-Z0-9,\s_.-]+$') {
        FailTask "itemsInScope contains invalid characters. Allowed: alphanumeric, comma, space, underscore, dash, dot"
    }
}

function Get-PythonExe {
    $py3 = Get-Command python3 -ErrorAction SilentlyContinue
    if ($py3) { return $py3.Source }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py) { return $py.Source }
    FailTask "Python executable not found."
}

function Ensure-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        FailTask "Azure CLI (az) not found."
    }
}

function Get-FederatedToken {
    param(
        [string] $explicitToken,
        [string] $tokenFile
    )

    if (-not [string]::IsNullOrWhiteSpace($explicitToken)) { return $explicitToken }
    if (-not [string]::IsNullOrWhiteSpace($tokenFile) -and (Test-Path $tokenFile)) {
        return Get-Content -Path $tokenFile -Raw
    }
    return $null
}

try {
    # Resolve credentials: prefer environment variables (from service connection), fallback to inputs
    $resolvedClientId = if (-not [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_ID)) { $env:AZURE_CLIENT_ID } else { $azureClientId }
    $resolvedClientSecret = if (-not [string]::IsNullOrWhiteSpace($env:AZURE_CLIENT_SECRET)) { $env:AZURE_CLIENT_SECRET } else { $azureClientSecret }
    $resolvedTenantId = if (-not [string]::IsNullOrWhiteSpace($env:AZURE_TENANT_ID)) { $env:AZURE_TENANT_ID } else { $azureTenantId }
    $resolvedAuthorityHost = if (-not [string]::IsNullOrWhiteSpace($env:AZURE_AUTHORITY_HOST)) { $env:AZURE_AUTHORITY_HOST } else { $null }

    # Best-effort discovery for federated tokens even if the wrapper didn't populate AZURE_FEDERATED_TOKEN(_FILE)
    # Exclude SYSTEMVSSCONNECTION tokens (Azure DevOps system access tokens, not Azure AD federated tokens)
    # Do NOT use SYSTEM_ACCESSTOKEN directly as a federated token; it is an ADO OAuth token
    $candidateTokenEnvNames = @(
        'AZURE_FEDERATED_TOKEN', 'ARM_OIDC_TOKEN', 'SYSTEM_OIDCTOKEN', 'SYSTEM_IDTOKEN'
    ) + (Get-ChildItem env: | Where-Object { $_.Name -match 'ENDPOINT_AUTH_PARAMETER_.*TOKEN$' -and $_.Name -notmatch 'SYSTEMVSSCONNECTION' }).Name

    $explicitFedToken = $null
    $usedTokenVar = $null
    foreach ($name in $candidateTokenEnvNames) {
        $val = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($val)) { $explicitFedToken = $val; $usedTokenVar = $name; break }
    }

    $tokenFile = $env:AZURE_FEDERATED_TOKEN_FILE
    if ([string]::IsNullOrWhiteSpace($tokenFile)) { $tokenFile = $env:ARM_OIDC_TOKEN_FILE }

    if (-not $explicitFedToken) {
        Log "WARN" "No federated token found. Searched env vars: $([string]::Join(', ', $candidateTokenEnvNames))"
    } else {
        Log "INFO" "Federated token discovered in env var: $usedTokenVar (value not logged)."
    }

    # Federated token detection (Workload Identity Federation) - keep previously found token, otherwise fallback to canonical names
    if ([string]::IsNullOrWhiteSpace($explicitFedToken)) {
        $explicitFedToken = $env:AZURE_FEDERATED_TOKEN
    }
    if ([string]::IsNullOrWhiteSpace($explicitFedToken)) {
        $explicitFedToken = $env:ARM_OIDC_TOKEN
    }

    $federatedToken = Get-FederatedToken -explicitToken $explicitFedToken -tokenFile $tokenFile

    # Basic validations
    Validate-Guid $resolvedClientId "azureClientId"
    Validate-Guid $resolvedTenantId "azureTenantId"
    Validate-Guid $workspaceId "workspaceId"
    Validate-Path $repositoryDirectory "repositoryDirectory"
    Validate-Path $configFilePath "configFilePath"
    Validate-ItemsInScope $itemsInScope

    if ([string]::IsNullOrWhiteSpace($resolvedClientId) -or [string]::IsNullOrWhiteSpace($resolvedTenantId)) {
        FailTask "Missing credentials. Provide service connection or azureClientId/azureTenantId inputs."
    }

    $hasSecret = -not [string]::IsNullOrWhiteSpace($resolvedClientSecret)
    $hasFederatedToken = -not [string]::IsNullOrWhiteSpace($federatedToken)

    if (-not $hasSecret -and -not $hasFederatedToken) {
        FailTask "No authentication material detected. Provide either a client secret or use a service connection configured with Workload Identity Federation."
    }

    # Export to env for child processes (python, az)
    $env:AZURE_CLIENT_ID = $resolvedClientId
    $env:AZURE_CLIENT_SECRET = $resolvedClientSecret
    $env:AZURE_TENANT_ID = $resolvedTenantId
    if (-not [string]::IsNullOrWhiteSpace($resolvedAuthorityHost)) { $env:AZURE_AUTHORITY_HOST = $resolvedAuthorityHost }
    if ($hasFederatedToken) {
        $env:AZURE_FEDERATED_TOKEN = $federatedToken
        # If token file not provided, create one so SDKs relying on AZURE_FEDERATED_TOKEN_FILE can work
        if ([string]::IsNullOrWhiteSpace($tokenFile)) {
            $tokenFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "federated_token_$([guid]::NewGuid().Guid).jwt")
            Set-Content -Path $tokenFile -Value $federatedToken -Encoding UTF8 -Force
        }
        $env:AZURE_FEDERATED_TOKEN_FILE = $tokenFile
    }

    # Python check
    $pythonExe = Get-PythonExe
    Log "INFO" "Using Python at $pythonExe"
    $ver = & $pythonExe --version 2>&1
    Log "INFO" "Detected $ver"
    if ($ver -match "Python (\d+)\.(\d+)\.(\d+)") {
        $maj = [int]$matches[1]; $min = [int]$matches[2]
        if ($maj -ne 3 -or $min -lt 9 -or $min -ge 15) {
            FailTask "Python must be >=3.9 and <3.15. Found $ver"
        }
    }

    # Azure CLI check + login using environment variables (avoid passing secrets in args from task)
    Ensure-AzCli
    if ($hasSecret) {
        Log "INFO" "Logging in to Azure with service principal secret..."
        az login --service-principal `
            --username $env:AZURE_CLIENT_ID `
            --password $env:AZURE_CLIENT_SECRET `
            --tenant $env:AZURE_TENANT_ID | Out-Null
        Log "SUCCESS" "Azure CLI login (secret) OK"
    } elseif ($hasFederatedToken) {
        Log "INFO" "Logging in to Azure with workload identity federation..."
        $azLoginOutput = az login --service-principal `
            --username $env:AZURE_CLIENT_ID `
            --tenant $env:AZURE_TENANT_ID `
            --federated-token $federatedToken `
            --allow-no-subscriptions 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log "SUCCESS" "Azure CLI login (federated) OK"
        } else {
            Log "WARN" "Azure CLI login reported warnings/errors but may have succeeded. Exit code: $LASTEXITCODE"
        }
    }

    # Attempt to establish Az PowerShell context to mirror blog guidance and emit bearer token for Fabric API
    try {
        Import-Module Az.Accounts -ErrorAction Stop | Out-Null

        if ($hasSecret) {
            $secPwd = ConvertTo-SecureString $resolvedClientSecret -AsPlainText -Force
            $psCred = New-Object System.Management.Automation.PSCredential($resolvedClientId, $secPwd)
            Connect-AzAccount -ServicePrincipal -ApplicationId $resolvedClientId -Tenant $resolvedTenantId -Credential $psCred -ErrorAction Stop | Out-Null
        } elseif ($hasFederatedToken) {
            # Ensure Az.Accounts module version supports -FederatedToken (requires 2.7.0+)
            Connect-AzAccount -ServicePrincipal -Tenant $resolvedTenantId -ApplicationId $resolvedClientId -FederatedToken $federatedToken -ErrorAction Stop | Out-Null
        }

        $accessToken = Get-AzAccessToken -ResourceUrl "https://api.fabric.microsoft.com" -ErrorAction SilentlyContinue
        if ($accessToken -and $accessToken.Token) {
            if ($accessToken.Token -is [SecureString]) {
                $bearerToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($accessToken.Token))
            } else {
                $bearerToken = $accessToken.Token
            }
            $env:FABRIC_BEARER_TOKEN = $bearerToken
            Log "INFO" "Fabric bearer token acquired via Get-AzAccessToken"
        }
    }
    catch {
        Log "WARN" "Unable to initialize Az PowerShell context or acquire Fabric bearer token: $($_.Exception.Message)"
    }

    # Install fabric-cicd
    Log "INFO" "Upgrading pip..."
    & $pythonExe -m pip install --upgrade pip
    
    $pipIndex = "https://pypi.org/simple"
    if ([string]::IsNullOrWhiteSpace($fabricCicdVersion)) {
        Log "WARN" "No version specified. Consider pinning fabric-cicd version for reproducibility."
        Log "INFO" "Installing latest fabric-cicd..."
        & $pythonExe -m pip install fabric-cicd --upgrade --index-url $pipIndex
    } else {
        # Validate version format (e.g., 1.2.3 or 1.2.3a1)
        if ($fabricCicdVersion -notmatch '^\d+\.\d+(\.\d+)?([a-z]\d+)?$') {
            FailTask "Invalid version format: $fabricCicdVersion (expected format: 1.2.3 or 1.2.3a1)"
        }
        Log "INFO" "Installing fabric-cicd==$fabricCicdVersion..."
        & $pythonExe -m pip install "fabric-cicd==$fabricCicdVersion" --index-url $pipIndex
    }

    # Deploy
    if (($includeConfig -eq '1' -or $includeConfig -eq 'True' -or $includeConfig -eq 'true') -and -not [string]::IsNullOrWhiteSpace($configFilePath)) {
        Log "INFO" "Using config file for deployment..."

        $scriptPath = Join-Path $scriptsFolder "auth_spn_deploy_config.py"
        
        & $pythonExe $scriptPath `
            --ConfigFilePath $configFilePath `
            --Environment $environmentName
    } elseif ([string]::IsNullOrWhiteSpace($itemsInScope)) {
        Log "INFO" "Deploying all items..."

        $scriptPath = Join-Path $scriptsFolder "auth_spn_deploy_all_workspace.py"

        & $pythonExe $scriptPath `
            --WorkspaceId $workspaceId `
            --Environment $environmentName `
            --RepositoryDirectory $repositoryDirectory
    } else {
        Log "INFO" "Deploying selected items..."
        $scriptPath = Join-Path $scriptsFolder "auth_spn_deploy_fabric_items.py"
        & $pythonExe $scriptPath `
            --WorkspaceId $workspaceId `
            --Environment $environmentName `
            --RepositoryDirectory $repositoryDirectory `
            --ItemsInScope $itemsInScope
    }

    if ($LASTEXITCODE -ne 0) { FailTask "Deployment failed: $LASTEXITCODE" }
    Log "SUCCESS" "Deployment complete."
    exit 0
}
catch {
    FailTask "Task failed: $($_.Exception.Message)"
}
