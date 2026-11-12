# Lanza AgentCraft usando la API de NVIDIA en vez de Claude.
# Uso (desde la carpeta de agentcraft):
#   .\iniciar-nvidia.ps1 -Repo C:\ruta\a\tu\repo
#
# Requisitos: tener NVIDIA_API_KEY guardada (setx NVIDIA_API_KEY nvapi-...)
#             y LiteLLM instalado (pip install "litellm[proxy]")

param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [int]$ProxyPort = 4000
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $env:NVIDIA_API_KEY) { throw 'Falta NVIDIA_API_KEY. Ejecuta: setx NVIDIA_API_KEY nvapi-...  y abre otra terminal.' }

# LiteLLM requires a master key; keep one per Windows user so separate terminals agree.
if (-not $env:LITELLM_MASTER_KEY) {
    $env:LITELLM_MASTER_KEY = [Environment]::GetEnvironmentVariable('LITELLM_MASTER_KEY', 'User')
}
if (-not $env:LITELLM_MASTER_KEY) {
    $keyBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($keyBytes) } finally { $rng.Dispose() }
    $env:LITELLM_MASTER_KEY = 'sk-' + [Convert]::ToBase64String($keyBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [Environment]::SetEnvironmentVariable('LITELLM_MASTER_KEY', $env:LITELLM_MASTER_KEY, 'User')
}
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

# 1) Levantar el traductor LiteLLM si no está corriendo
$up = $false
try { Invoke-WebRequest "http://127.0.0.1:$ProxyPort/health/liveliness" -UseBasicParsing -TimeoutSec 2 | Out-Null; $up = $true } catch {}
if (-not $up) {
    Write-Host "Iniciando LiteLLM en el puerto $ProxyPort..."
    Start-Process -WindowStyle Minimized litellm -ArgumentList @('--config', (Join-Path $here 'litellm-nvidia.yaml'), '--host', '127.0.0.1', '--port', $ProxyPort)
    for ($i = 0; $i -lt 60 -and -not $up; $i++) {
        Start-Sleep 1
        try { Invoke-WebRequest "http://127.0.0.1:$ProxyPort/health/liveliness" -UseBasicParsing -TimeoutSec 2 | Out-Null; $up = $true } catch {}
    }
    if (-not $up) { throw 'LiteLLM no arrancó. Ejecútalo a mano para ver el error: litellm --config litellm-nvidia.yaml' }
}

# 2) Hacer que los agentes (Claude Agent SDK) hablen con LiteLLM y no con Anthropic
Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue      # que no use una key real por error
$env:ANTHROPIC_BASE_URL          = "http://127.0.0.1:$ProxyPort"
$env:ANTHROPIC_AUTH_TOKEN        = $env:LITELLM_MASTER_KEY
$env:ANTHROPIC_MODEL             = 'nvidia-worker'
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = 'nvidia-lead'
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'nvidia-worker'
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = 'nvidia-fast'
$env:ANTHROPIC_SMALL_FAST_MODEL     = 'nvidia-fast'
$env:CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS   = '1'
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'

# 3) Lanzar AgentCraft (2 programadores, de a uno por vez: el plan gratis de NVIDIA limita peticiones por minuto)
& (Join-Path $here 'tools\launch.ps1') -Repo $Repo -ForemanArgs @(
    '--lead-model', 'nvidia-lead',
    '--worker-model', 'nvidia-worker',
    '--workers', 'juniper,kit',
    '--max-concurrent', '1'
)
