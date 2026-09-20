<#
===============================================================================
  EXPERTISE TECNOLOGIA
===============================================================================
  Script      : WindowsOptimizerCleanup.ps1
  Descricao   : Limpeza e otimizacao de Windows com aplicacao de boas
                praticas Microsoft (temporarios, cache de navegadores,
                Lixeira, cache do Windows Update, DISM, SFC e, de forma
                opcional, atualizacao do PowerShell 7), com log, relatorio
                de espaco, modo simulacao e relatorio JSON para RMM.
  Setor       : Tecnologia da Informacao / NOC
  Autor       : Pablo Fernando Schutz
  Empresa     : Expertise Tecnologia
  Versao      : 3.0.0
  Data        : 20/09/2026
  Licenca     : Expertise4All - uso publico e liberado (ver arquivo LICENSE)
  Requisitos  : Windows 10/11 ou Windows Server 2016 ou superior | PowerShell 5.1+
                Executar como Administrador
                Acesso a internet (github.com) e opcional - usado so se o
                operador escolher verificar/instalar o PowerShell 7 (Passo 1)
  Uso         : powershell -ExecutionPolicy Bypass -File .\WindowsOptimizerCleanup.ps1
                Parametros (todos opcionais):
                  -PowerShell7 <Perguntar|Sim|Nao>  Passo 1 (padrao: Perguntar;
                       sem console interativo, "Perguntar" equivale a "Nao")
                  -HabilitarPSRemoting  Habilita o PS Remoting na instalacao do
                       PowerShell 7 (padrao: desabilitado)
                  -Simular (alias -WhatIf)  Nao altera nada: registra e estima
                       o que seria feito (inclusive o espaco recuperavel)
                  -Pular <passos>  Ignora passos, ex.: -Pular 3,6 (1 a 10)
                  -RelatorioJson <caminho>  Grava um relatorio JSON (arquivo ou
                       pasta) com status, tempo e espaco de cada passo
                Codigos de saida: 0 = OK | 1 = com ALERTA | 2 = com FALHA |
                       3 = nao iniciou (sem elevacao ou parametro invalido)
-------------------------------------------------------------------------------
  Site        : https://www.expertise.tec.br/
  LinkedIn    : https://www.linkedin.com/company/expertisetec/
  Instagram   : https://www.instagram.com/expertisetec
  GitHub      : https://github.com/expertisetec
===============================================================================
  HISTORICO DE VERSOES: ver CHANGELOG.md na raiz do repositorio.
===============================================================================
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidateSet('Perguntar', 'Sim', 'Nao')]
    [string]$PowerShell7 = 'Perguntar',

    [switch]$HabilitarPSRemoting,

    [Alias('WhatIf')]
    [switch]$Simular,

    [string[]]$Pular,

    [string]$RelatorioJson
)

# -----------------------------------------------------------------------------
# VERIFICACOES INICIAIS (elevacao e parametros)
# O "#Requires -RunAsAdministrator" so e' aplicado quando o script roda como
# arquivo; via "irm | iex" ele e' apenas um comentario. Por isso a checagem
# explicita aqui, antes de qualquer alteracao no sistema. Falhas nesta etapa
# encerram com o codigo de saida 3 (sem exit quando nao ha arquivo, para nunca
# fechar o console de quem executou via irm | iex).
# -----------------------------------------------------------------------------
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-StepNumberList {
    <#  Converte o valor de -Pular em uma lista de numeros de passos (1 a $Max).
        Aceita "3,6", "3 6", @('3','6') e @(3,6): o "-File" do powershell.exe
        entrega "3,6" como uma unica string, entao a separacao e' feita aqui.
        Lanca excecao para valores que nao sejam numeros de passos validos. #>
    param([string[]]$Value, [int]$Max = 10)
    $numbers = @()
    foreach ($item in @($Value)) {
        foreach ($token in ("$item" -split '[,;\s]+')) {
            if ([string]::IsNullOrWhiteSpace($token)) { continue }
            $number = 0
            if (-not [int]::TryParse($token, [ref]$number) -or $number -lt 1 -or $number -gt $Max) {
                throw "Valor invalido em -Pular: '$token' (use numeros de 1 a $Max, ex.: -Pular 3,6)."
            }
            if ($numbers -notcontains $number) { $numbers += $number }
        }
    }
    return @($numbers | Sort-Object)
}

if (-not (Test-IsAdministrator)) {
    Write-Host 'ERRO: este script precisa ser executado como Administrador.' -ForegroundColor Red
    Write-Host 'Abra o PowerShell com "Executar como administrador" e execute novamente.' -ForegroundColor Red
    if ($PSCommandPath) { exit 3 } else { $global:LASTEXITCODE = 3; return }
}

try {
    $SkipSteps = @(ConvertTo-StepNumberList -Value $Pular)
} catch {
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    if ($PSCommandPath) { exit 3 } else { $global:LASTEXITCODE = 3; return }
}

# -----------------------------------------------------------------------------
# CONFIGURACAO INICIAL E LOG
# -----------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
$ScriptVersion = '3.0.0'
$StartedAt = Get-Date
$SystemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
$SystemRoot  = if ($env:SystemRoot)  { $env:SystemRoot }  else { Join-Path $SystemDrive 'Windows' }
$LogDir  = Join-Path $SystemDrive 'Expertise\Logs'
$LogFile = Join-Path $LogDir ("WindowsOptimizerCleanup_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

# Estado compartilhado da execucao. E' uma tabela hash (tipo por referencia) de
# proposito: um "$script:variavel" NAO chega ao nivel superior quando o script
# roda via & ([scriptblock]::Create(...)), e o resumo final leria valor antigo.
$RunState = @{
    SfcRepairStatus = 'NotRun'   # NotRun | Simulated | Clean | Repaired | Unrepaired | Unknown
    SimulatedBytes  = 0L         # acumulado do passo corrente, em modo simulacao
    SimulatedPaths  = @{}        # pastas ja contabilizadas na simulacao (evita contar duas vezes)
    RebootBefore    = $null      # resultado de Get-PendingReboot antes do servicing
    Notice          = ''         # aviso exibido no menu de passos
}
$StepReport = [ordered]@{}       # detalhes por passo (tempo, espaco), por chave de passo

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

# $ScriptVersion (acima) e' a fonte de verdade em tempo de execucao. O campo
# "Versao" no cabecalho existe para leitura humana e precisa ser mantido
# igual manualmente. Quando executado como arquivo local (nao via irm | iex,
# onde nao ha arquivo para ler), avisa se os dois divergirem.
if ($PSCommandPath) {
    $headerMatch = Select-String -Path $PSCommandPath -Pattern 'Versao\s*:\s*(\S+)' | Select-Object -First 1
    if ($headerMatch -and $headerMatch.Matches[0].Groups[1].Value -ne $ScriptVersion) {
        Write-Warning "Versao do cabecalho ($($headerMatch.Matches[0].Groups[1].Value)) difere de `$ScriptVersion ($ScriptVersion). Corrija antes de publicar."
    }
}

# -----------------------------------------------------------------------------
# FUNCOES AUXILIARES
# -----------------------------------------------------------------------------

function Write-Log {
    <#  Grava apenas no arquivo de log (o console e' controlado pelo menu de
        passos em Show-StepMenu, para manter a tela limpa). #>
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line
}

function Clear-ConsoleSafe {
    <#  Clear-Host lanca excecao em hosts sem console real (ex.: saida
        redirecionada por ferramentas de RMM/agendador); nesse caso a
        execucao segue sem limpar a tela. #>
    try { Clear-Host } catch { Write-Verbose 'Clear-Host indisponivel neste host.' }
}

function Test-InteractiveConsole {
    <#  $true se ha um console interativo para responder perguntas (nao e'
        RMM/agendador e a entrada nao esta redirecionada). #>
    try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) } catch { return $false }
}

function Get-FreeSpaceGB {
    [math]::Round((Get-PSDrive -Name $SystemDrive.TrimEnd(':')).Free / 1GB, 2)
}

function Test-IsServerOS {
    <#  $true em Windows Server (ProductType 2 ou 3), $false em Windows
        cliente. Se nao for possivel consultar, assume cliente (lado mais
        conservador para os passos que dependem disso). #>
    try {
        return ((Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).ProductType -ne 1)
    } catch {
        return $false
    }
}

function Get-DirectorySizeBytes {
    <#  Tamanho total (bytes) dos arquivos de uma pasta, recursivo, sem entrar
        em junctions/links simbolicos. Usado para estimar o espaco no modo
        simulacao. Itens inacessiveis sao ignorados. #>
    param([Parameter(Mandatory)] [System.IO.DirectoryInfo]$Directory)
    $total = 0L
    try {
        foreach ($item in $Directory.EnumerateFileSystemInfos()) {
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($item -is [System.IO.DirectoryInfo]) { $total += Get-DirectorySizeBytes -Directory $item }
            else { $total += $item.Length }
        }
    } catch {
        Write-Verbose "Pasta inacessivel ao estimar tamanho: $($Directory.FullName)"
    }
    return $total
}

function Clear-Folder {
    <#  Remove o CONTEUDO de uma pasta de forma segura (a pasta em si e mantida).
        Arquivos em uso sao ignorados sem interromper o script. Junctions e
        links simbolicos diretamente dentro da pasta tem apenas o link
        removido, nunca o conteudo do destino (medida defensiva: em testes
        no Windows 10 22H2 o Remove-Item ja preservava o destino, mas nao ha
        garantia equivalente em todas as builds suportadas).
        Em modo simulacao ($Simular) nada e' removido: o tamanho do conteudo
        e' somado em $RunState.SimulatedBytes e registrado no log. #>
    param([string]$Path, [string]$Description)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Pasta nao encontrada, ignorando: $Path" 'WARN'
        return
    }
    $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($Simular) {
        # A mesma pasta pode ser visitada mais de uma vez (ex.: o %TEMP% do
        # usuario atual tambem e' o Temp do perfil dele); conta uma vez so.
        if (-not $RunState.SimulatedPaths) { $RunState.SimulatedPaths = @{} }
        $pathKey = [System.IO.Path]::GetFullPath($Path).TrimEnd('\').ToLowerInvariant()
        if ($RunState.SimulatedPaths.ContainsKey($pathKey)) {
            Write-Log "[SIMULACAO] Pasta ja contabilizada, ignorando: $Path"
            return
        }
        $RunState.SimulatedPaths[$pathKey] = $true
        $bytes = 0L
        foreach ($child in $children) {
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($child.PSIsContainer) { $bytes += Get-DirectorySizeBytes -Directory $child }
            else { $bytes += $child.Length }
        }
        $RunState.SimulatedBytes += $bytes
        Write-Log ("[SIMULACAO] Removeria o conteudo de: {0} ({1}) - {2:N1} MB" -f $Description, $Path, ($bytes / 1MB))
        return
    }
    Write-Log "Limpando: $Description ($Path)"
    foreach ($child in $children) {
        if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            try { $child.Delete() } catch { Write-Log "Nao foi possivel remover o link: $($child.FullName)" 'WARN' }
        } else {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-UserProfileFolder {
    <#  Pastas de perfil de usuario (diretorio-base lido do registro, com
        fallback para <unidade do sistema>\Users). Ignora junctions. #>
    $usersRoot = Join-Path $SystemDrive 'Users'
    try {
        $configured = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name ProfilesDirectory -ErrorAction Stop).ProfilesDirectory
        if ($configured) { $usersRoot = [Environment]::ExpandEnvironmentVariables($configured) }
    } catch {
        Write-Log 'ProfilesDirectory nao encontrado no registro; usando o padrao.' 'WARN'
    }
    Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) }
}

function Get-PendingReboot {
    <#  Detecta se o Windows tem reinicializacao pendente, pelos indicadores
        classicos de registro. Retorna [pscustomobject] com IsPending ($true/
        $false) e Reasons (lista de motivos em texto). Somente leitura.
        Obs: PendingFileRenameOperations tambem e' preenchido por alguns
        instaladores/antivirus; e' um indicador, nao uma certeza. #>
    $reasons = @()
    $cbsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wuKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if (Test-Path -LiteralPath $cbsKey) { $reasons += 'Component Based Servicing (CBS)' }
    if (Test-Path -LiteralPath $wuKey)  { $reasons += 'Windows Update' }
    try {
        $renames = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations
        if ($renames) { $reasons += 'Arquivos pendentes de renomear/excluir (PendingFileRenameOperations)' }
    } catch {
        Write-Verbose 'PendingFileRenameOperations ausente (nenhuma renomeacao pendente).'
    }
    try {
        $activeName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
        $newName    = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
        if ($activeName -and $newName -and $activeName -ne $newName) { $reasons += 'Troca de nome do computador pendente' }
    } catch {
        Write-Verbose 'Nao foi possivel comparar o nome ativo do computador.'
    }
    return [pscustomobject]@{ IsPending = ($reasons.Count -gt 0); Reasons = $reasons }
}

function Get-ExitCodeFromStatus {
    <#  Codigo de saida a partir dos status dos passos: 2 se algum FALHA,
        1 se algum ALERTA, 0 caso contrario (OK, Ignorado, Simulado). #>
    param([string[]]$Status)
    if ($Status -contains 'FALHA')  { return 2 }
    if ($Status -contains 'ALERTA') { return 1 }
    return 0
}

# --- Menu fixo de passos (evita poluir o console com dezenas de linhas) ------
# Obs: as chaves de $Steps/$StepStatus sao strings ('1', '2', ...) de proposito.
# Um [ordered]@{} com chaves inteiras e' indexado POSICIONALMENTE pelo
# PowerShell ($h[1] retorna o 2o item, nao o item de chave 1), o que quebraria
# a busca por chave usada abaixo.
#
# Ordem dos passos de servicing (7 a 10): segue a recomendacao da Microsoft de
# rodar o DISM /RestoreHealth ANTES do SFC (o DISM fornece os arquivos que o
# SFC usa para reparar). O /StartComponentCleanup vem por ultimo, depois de
# qualquer reparo.

$Steps = [ordered]@{
    '1'  = 'Verificar/atualizar PowerShell 7'
    '2'  = 'Limpeza de temporarios'
    '3'  = 'Cache de navegadores'
    '4'  = 'Lixeira'
    '5'  = 'Cache do Windows Update'
    '6'  = 'Logs e caches secundarios'
    '7'  = 'DISM - AnalyzeComponentStore'
    '8'  = 'DISM - RestoreHealth'
    '9'  = 'SFC /scannow'
    '10' = 'DISM - StartComponentCleanup'
}
$StepStatus = [ordered]@{}
foreach ($key in $Steps.Keys) { $StepStatus[$key] = 'Pendente' }

function Format-StepLine {
    param([string]$Label, [string]$Status)
    $width = 42
    $dots = if ($Label.Length -lt $width) { '.' * ($width - $Label.Length) } else { '..' }
    return "  $Label $dots $Status"
}

function Show-StepMenu {
    param(
        [string]$CurrentStep = '0',
        [string]$CurrentDetail = ''
    )
    Clear-ConsoleSafe
    Write-Host '===============================================================' -ForegroundColor Cyan
    Write-Host ' EXPERTISE TECNOLOGIA - WindowsOptimizerCleanup' -ForegroundColor Cyan
    Write-Host " Setor: Tecnologia da Informacao / NOC | Versao: $ScriptVersion" -ForegroundColor Cyan
    Write-Host " Computador: $env:COMPUTERNAME | Usuario: $env:USERNAME" -ForegroundColor Cyan
    if ($Simular) {
        Write-Host ' *** MODO SIMULACAO: nenhuma alteracao sera feita no sistema ***' -ForegroundColor Yellow
    }
    Write-Host '===============================================================' -ForegroundColor Cyan
    foreach ($key in $Steps.Keys) {
        $status = $StepStatus[$key]
        $detail = if ($key -eq $CurrentStep) { $CurrentDetail } else { '' }
        $line = Format-StepLine -Label ("[{0}] {1}" -f $key, $Steps[$key]) -Status "$status$detail"
        switch -Regex ($status) {
            '^OK$'            { Write-Host $line -ForegroundColor Green }
            '^Simulado$'      { Write-Host $line -ForegroundColor Cyan }
            '^ALERTA$'        { Write-Host $line -ForegroundColor Yellow }
            '^FALHA$'         { Write-Host $line -ForegroundColor Red }
            '^Executando'     { Write-Host $line -ForegroundColor Yellow }
            default           { Write-Host $line -ForegroundColor DarkGray }
        }
    }
    Write-Host '===============================================================' -ForegroundColor Cyan
    if ($RunState.Notice) { Write-Host " Aviso: $($RunState.Notice)" -ForegroundColor Yellow }
    Write-Host " Log: $LogFile" -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-Step {
    <#  Executa um passo, atualizando o menu antes/depois. O scriptblock pode
        ajustar $StepStatus[$StepKey] para 'ALERTA' (ex: exit code != 0) sem
        que isso seja tratado como falha do script. Passos listados em -Pular
        (ou com -SkipReason informado) nao executam: ficam como 'Ignorado'.
        Registra em $StepReport o tempo e a variacao de espaco livre do passo
        (a variacao e' aproximada: outros processos tambem escrevem em disco). #>
    param(
        [Parameter(Mandatory)] [string]$StepKey,
        [Parameter(Mandatory)] [scriptblock]$Action,
        [string]$SkipReason = ''
    )
    $reason = $SkipReason
    if (-not $reason -and $SkipSteps -contains [int]$StepKey) { $reason = 'parametro -Pular' }
    if ($reason) {
        $StepStatus[$StepKey] = 'Ignorado'
        Write-Log "Passo $StepKey ($($Steps[$StepKey])) ignorado: $reason."
        Show-StepMenu -CurrentStep $StepKey
        return
    }

    $StepStatus[$StepKey] = 'Executando...'
    Show-StepMenu -CurrentStep $StepKey
    $RunState.SimulatedBytes = 0L
    $freeBefore = Get-FreeSpaceGB
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        if ($StepStatus[$StepKey] -eq 'Executando...') {
            $StepStatus[$StepKey] = if ($Simular) { 'Simulado' } else { 'OK' }
        }
    } catch {
        Write-Log "Passo $StepKey ($($Steps[$StepKey])) falhou: $($_.Exception.Message)" 'ERRO'
        $StepStatus[$StepKey] = 'FALHA'
    }
    $stopwatch.Stop()
    $freeAfter = Get-FreeSpaceGB
    $StepReport[$StepKey] = [pscustomobject]@{
        DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        FreeBeforeGB    = $freeBefore
        FreeAfterGB     = $freeAfter
        EstimatedBytes  = [long]$RunState.SimulatedBytes
    }
    Show-StepMenu -CurrentStep $StepKey
}

function Invoke-DismStep {
    <#  Roda o DISM redirecionando a saida para um arquivo temporario e le a
        ultima porcentagem reportada, atualizando o menu fixo em vez de
        imprimir uma linha nova no console a cada atualizacao (comportamento
        padrao do DISM quando a saida e' redirecionada/tee'ada). Em modo
        simulacao apenas registra o comando e retorna 0. #>
    param(
        [Parameter(Mandatory)] [string]$StepKey,
        [Parameter(Mandatory)] [string[]]$ArgumentList
    )
    if ($Simular) {
        Write-Log ("[SIMULACAO] Executaria: dism.exe {0}" -f ($ArgumentList -join ' '))
        return 0
    }
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $lastPercent = $null
    $exitCode = -1
    try {
        $proc = Start-Process -FilePath 'dism.exe' -ArgumentList $ArgumentList -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 400
            $raw = Get-Content -Path $tmpOut -Raw -ErrorAction SilentlyContinue
            if ($raw) {
                $percentMatches = [regex]::Matches($raw, '(\d{1,3}[.,]\d)\s*%')
                if ($percentMatches.Count -gt 0) {
                    $percent = $percentMatches[$percentMatches.Count - 1].Groups[1].Value
                    if ($percent -ne $lastPercent) {
                        $lastPercent = $percent
                        Show-StepMenu -CurrentStep $StepKey -CurrentDetail " ($percent%)"
                    }
                }
            }
        }
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
    } finally {
        if (Test-Path $tmpOut) {
            $rawOut = Get-Content -Path $tmpOut -Raw -ErrorAction SilentlyContinue
            if ($rawOut) { Add-Content -Path $LogFile -Value $rawOut }
            Remove-Item -Path $tmpOut -Force -ErrorAction SilentlyContinue
        }
    }
    return $exitCode
}

# --- Perguntas ao operador ---------------------------------------------------

function Read-YesNo {
    <#  Pergunta S/N ao operador. Enter (resposta vazia) assume $Default. Se
        o host nao permitir leitura (sem console interativo), assume $Default
        em vez de travar ou falhar. #>
    param([string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { '(S/N, padrao S)' } else { '(S/N, padrao N)' }
    while ($true) {
        try { $answer = Read-Host "$Prompt $hint" } catch { return $Default }
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch -Regex ($answer.Trim()) {
            '^(s|sim|y|yes)$' { return $true }
            '^(n|nao|no)$'    { return $false }
        }
        Write-Host 'Resposta invalida. Digite S ou N.' -ForegroundColor Yellow
    }
}

function Resolve-PowerShell7Choice {
    <#  Decide se o Passo 1 (PowerShell 7) deve rodar. "Sim"/"Nao" vem do
        parametro -PowerShell7; "Perguntar" (padrao) pergunta ao operador.
        Sem console interativo, nao ha quem responder: assume Nao, para nunca
        instalar software sem consentimento. #>
    param([string]$Choice)
    if ($Choice -eq 'Sim') { return $true }
    if ($Choice -eq 'Nao') { return $false }
    if (-not (Test-InteractiveConsole)) { return $false }

    Clear-ConsoleSafe
    Write-Host '===============================================================' -ForegroundColor Cyan
    Write-Host " EXPERTISE TECNOLOGIA - WindowsOptimizerCleanup  v$ScriptVersion" -ForegroundColor Cyan
    Write-Host '===============================================================' -ForegroundColor Cyan
    Write-Host ''
    if ($Simular) {
        Write-Host '*** MODO SIMULACAO: nada sera baixado nem instalado. ***' -ForegroundColor Yellow
        Write-Host ''
    }
    Write-Host 'Passo opcional: verificar/instalar/atualizar o PowerShell 7' -ForegroundColor White
    Write-Host '  - Consulta a versao mais recente no GitHub (PowerShell/PowerShell).'
    Write-Host '  - Se ausente ou desatualizado, baixa o MSI oficial, valida a assinatura'
    Write-Host '    digital da Microsoft e instala em modo silencioso.'
    Write-Host '  - Instala lado a lado com o Windows PowerShell 5.1 (nao o substitui).'
    Write-Host '  - Requer acesso a internet (github.com). Falhas nao interrompem a limpeza.'
    Write-Host ''
    return (Read-YesNo -Prompt 'Deseja executar este passo?' -Default $false)
}

# --- PowerShell 7: verificacao/atualizacao (Passo 1, opcional) ----------------

function Get-InstalledPwshVersion {
    <#  Retorna a versao instalada do PowerShell 7 (pwsh.exe) como [version],
        ou $null se nao estiver instalado. #>
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $pwshPath = Join-Path $programFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path $pwshPath)) {
        $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($cmd) { $pwshPath = $cmd.Source } else { return $null }
    }
    try {
        $verText = & $pwshPath -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
        if ($verText) { return [version](($verText | Select-Object -Last 1).Trim()) }
    } catch {
        Write-Log "Nao foi possivel ler a versao do pwsh.exe: $($_.Exception.Message)" 'WARN'
    }
    return $null
}

function Get-PwshMsiSuffix {
    <#  Sufixo do arquivo MSI do PowerShell 7 conforme a arquitetura do
        Windows (o PROCESSOR_ARCHITEW6432 cobre um PowerShell de 32 bits
        rodando em Windows de 64 bits). #>
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($arch) {
        'ARM64' { return 'win-arm64.msi' }
        'x86'   { return 'win-x86.msi' }
        default { return 'win-x64.msi' }
    }
}

function Select-PwshRelease {
    <#  Dentre as releases do GitHub, escolhe a mais recente que seja estavel
        (nao rascunho/preview) E que tenha o instalador MSI da arquitetura
        pedida. A exigencia do MSI e' proposital: a partir do PowerShell 7.7
        a Microsoft publica apenas MSIX, entao "a ultima release" pode nao ter
        MSI - nesse caso vale a mais recente que tenha. Retorna $null se nao
        houver nenhuma. #>
    param([object[]]$Releases, [string]$AssetSuffix)
    $candidates = foreach ($release in $Releases) {
        if ($release.draft -or $release.prerelease) { continue }
        $parsed = $null
        if (-not [version]::TryParse("$($release.tag_name)".TrimStart('v'), [ref]$parsed)) { continue }
        $asset = $release.assets | Where-Object { $_.name -like "*$AssetSuffix" } | Select-Object -First 1
        if (-not $asset) { continue }
        $sha256 = $null
        if ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { $sha256 = $Matches[1] }
        [pscustomobject]@{
            Version     = $parsed
            DownloadUrl = $asset.browser_download_url
            FileName    = $asset.name
            Sha256      = $sha256
        }
    }
    return ($candidates | Sort-Object -Property Version -Descending | Select-Object -First 1)
}

function Get-LatestPwshRelease {
    <#  Consulta a API publica do GitHub e devolve a release mais recente do
        PowerShell 7 com MSI (ver Select-PwshRelease). Retorna $null se nao
        for possivel consultar (sem internet, GitHub bloqueado por firewall
        corporativo, limite de requisicoes, etc) - tratado como "nao foi
        possivel confirmar", nunca como erro fatal do script. #>
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Log "Nao foi possivel habilitar TLS 1.2 explicitamente: $($_.Exception.Message)" 'WARN'
    }
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $releases = Invoke-RestMethod -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop `
            -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases?per_page=30' `
            -Headers @{ 'User-Agent' = 'WindowsOptimizerCleanup'; 'Accept' = 'application/vnd.github+json' }
        return (Select-PwshRelease -Releases $releases -AssetSuffix (Get-PwshMsiSuffix))
    } catch {
        Write-Log "Falha ao consultar a API do GitHub: $($_.Exception.Message)" 'WARN'
        return $null
    } finally {
        $ProgressPreference = $previousProgress
    }
}

function Test-MicrosoftSignature {
    <#  $true se o arquivo tem assinatura Authenticode valida emitida em nome
        da Microsoft Corporation. #>
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -FilePath $Path
    return ($signature.Status -eq 'Valid' -and $signature.SignerCertificate -and $signature.SignerCertificate.Subject -match 'CN=Microsoft Corporation')
}

function Update-PowerShell7 {
    <#  Garante que o PowerShell 7 mais recente (com MSI) esteja instalado. E'
        um produto separado, instalado lado a lado com o Windows PowerShell
        5.1 - nao substitui nem reinicia o motor deste script, que continua
        rodando no PowerShell que ja estava em uso (ver CONTRIBUTING.md).
        So baixa/instala quando ausente ou desatualizado (instalacao MSI
        silenciosa via msiexec /quiet - metodo que a Microsoft recomenda
        para servidores; winget nao esta disponivel por padrao no Windows
        Server 2022 ou anterior). Antes de instalar, confere o SHA-256 (quando
        o GitHub informa) e exige assinatura Authenticode valida da Microsoft.
        O PS Remoting so e' habilitado se -EnablePSRemoting for informado.
        Com -Simulate apenas consulta (somente leitura) e registra o que
        faria, sem baixar nem instalar.
        Retorna $true (ja atualizado ou atualizado com sucesso), $false
        (tentou instalar e falhou, ou o instalador foi rejeitado) ou $null
        (nao foi possivel verificar, ex: sem internet). #>
    param([switch]$EnablePSRemoting, [switch]$Simulate)

    $installed = Get-InstalledPwshVersion
    if ($installed) { Write-Log "PowerShell 7 instalado: $installed" }
    else { Write-Log 'PowerShell 7 nao encontrado neste computador.' }

    $latest = Get-LatestPwshRelease
    if (-not $latest) {
        Write-Log 'Nao foi possivel obter a versao mais recente do PowerShell 7 com instalador MSI (sem internet, GitHub inacessivel ou nenhuma release com MSI).' 'WARN'
        return $null
    }
    Write-Log "Versao mais recente disponivel do PowerShell 7 (com MSI): $($latest.Version)"

    if ($installed -and $installed -ge $latest.Version) {
        Write-Log 'PowerShell 7 ja esta na versao mais recente.'
        return $true
    }

    if ($Simulate) {
        $remotingNote = if ($EnablePSRemoting) { ' com PS Remoting habilitado' } else { '' }
        Write-Log "[SIMULACAO] Baixaria e instalaria $($latest.FileName) (versao $($latest.Version))$remotingNote."
        return $true
    }

    Write-Log "Baixando $($latest.FileName)..."
    $msiPath = Join-Path $env:TEMP $latest.FileName
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop -Uri $latest.DownloadUrl -OutFile $msiPath
    } catch {
        Write-Log "Falha ao baixar o instalador do PowerShell 7: $($_.Exception.Message)" 'WARN'
        return $null
    } finally {
        $ProgressPreference = $previousProgress
    }

    if ($latest.Sha256) {
        $actualHash = (Get-FileHash -Path $msiPath -Algorithm SHA256).Hash
        if ($actualHash -ne $latest.Sha256) {
            Write-Log "SHA-256 do instalador NAO confere (esperado $($latest.Sha256), obtido $actualHash). Instalacao abortada." 'ERRO'
            Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
            return $false
        }
        Write-Log 'SHA-256 do instalador confere com o publicado pelo GitHub.'
    } else {
        Write-Log 'O GitHub nao informou SHA-256 para este arquivo; validando apenas a assinatura digital.' 'WARN'
    }
    if (-not (Test-MicrosoftSignature -Path $msiPath)) {
        Write-Log 'O instalador nao tem assinatura digital valida da Microsoft Corporation. Instalacao abortada.' 'ERRO'
        Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
        return $false
    }
    Write-Log 'Assinatura digital da Microsoft Corporation validada.'

    Write-Log 'Instalando PowerShell 7 silenciosamente (msiexec /quiet)...'
    $msiLog = Join-Path $LogDir ("PowerShell7-msi_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $msiArgs = @('/package', "`"$msiPath`"", '/quiet', '/norestart', '/L*v', "`"$msiLog`"", 'ADD_PATH=1', 'REGISTER_MANIFEST=1')
    if ($EnablePSRemoting) {
        $msiArgs += 'ENABLE_PSREMOTING=1'
        Write-Log 'PS Remoting sera habilitado (-HabilitarPSRemoting informado).'
    }
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue

    # 3010 = sucesso, reinicio necessario para concluir - nao tratamos como falha
    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Log "PowerShell 7 instalado/atualizado com sucesso (codigo de saida do msiexec: $($proc.ExitCode))."
        return $true
    } else {
        Write-Log "msiexec retornou codigo de saida $($proc.ExitCode) ao instalar o PowerShell 7 (log do MSI: $msiLog)." 'WARN'
        return $false
    }
}

# --- Cache de navegadores (por perfil de usuario) ----------------------------
# Obs: Internet Explorer - so INetCache. A pasta WebCache guarda o banco
# WebCacheV01.dat (historico, cookies e dados de sessao do IE/Edge legado),
# nao apenas cache; apagar isso contradiz a promessa de preservar historico.

$BrowserCachePatterns = @(
    @{ Browser = 'Internet Explorer'; RelativePath = 'AppData\Local\Microsoft\Windows\INetCache' }
    @{ Browser = 'Google Chrome';     RelativePath = 'AppData\Local\Google\Chrome\User Data\Default\Cache' }
    @{ Browser = 'Google Chrome';     RelativePath = 'AppData\Local\Google\Chrome\User Data\Default\Code Cache' }
    @{ Browser = 'Google Chrome';     RelativePath = 'AppData\Local\Google\Chrome\User Data\Profile *\Cache' }
    @{ Browser = 'Google Chrome';     RelativePath = 'AppData\Local\Google\Chrome\User Data\Profile *\Code Cache' }
    @{ Browser = 'Mozilla Firefox';   RelativePath = 'AppData\Local\Mozilla\Firefox\Profiles\*\cache2' }
    @{ Browser = 'Microsoft Edge';    RelativePath = 'AppData\Local\Microsoft\Edge\User Data\Default\Cache' }
    @{ Browser = 'Microsoft Edge';    RelativePath = 'AppData\Local\Microsoft\Edge\User Data\Default\Code Cache' }
    @{ Browser = 'Microsoft Edge';    RelativePath = 'AppData\Local\Microsoft\Edge\User Data\Profile *\Cache' }
    @{ Browser = 'Microsoft Edge';    RelativePath = 'AppData\Local\Microsoft\Edge\User Data\Profile *\Code Cache' }
    @{ Browser = 'Opera';             RelativePath = 'AppData\Local\Opera Software\Opera Stable\Cache' }
    @{ Browser = 'Opera';             RelativePath = 'AppData\Local\Opera Software\Opera Stable\Code Cache' }
)

function Clear-BrowserCache {
    param([string]$ProfilePath, [string]$UserName)
    foreach ($item in $BrowserCachePatterns) {
        $pattern = Join-Path $ProfilePath $item.RelativePath
        Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Clear-Folder -Path $_.FullName -Description "Cache do $($item.Browser) ($UserName)"
        }
    }
}

function Get-SfcRepairStatus {
    <#  Le o CBS.log e classifica o resultado do SFC desde $Since. Usa as tags
        internas "[SR]" do CBS.log (fixas em ingles, nao localizadas) em vez
        do texto que o sfc.exe imprime no console (esse sim varia conforme o
        idioma do Windows). Retorna:
          'Clean'      - SFC rodou e nao encontrou nada a reparar
          'Repaired'   - SFC reparou arquivos corrompidos
          'Unrepaired' - SFC encontrou arquivos que NAO conseguiu reparar
                         (tem prioridade sobre 'Repaired' se houver os dois)
          'Unknown'    - nao foi possivel confirmar (CBS.log ausente/ilegivel
                         ou sem nenhuma entrada [SR] na janela lida) #>
    param(
        [datetime]$Since,
        [string]$CbsLogPath = (Join-Path $SystemRoot 'Logs\CBS\CBS.log')
    )
    if (-not (Test-Path -LiteralPath $CbsLogPath)) { return 'Unknown' }
    try {
        $lines = Get-Content -LiteralPath $CbsLogPath -Tail 50000 -ErrorAction Stop | Where-Object { $_ -match '\[SR\]' }
    } catch {
        return 'Unknown'
    }
    $sawSfcActivity = $false
    $repaired = $false
    $unrepaired = $false
    foreach ($line in $lines) {
        if ($line.Length -lt 19) { continue }
        $ts = [datetime]::MinValue
        $parsed = [datetime]::TryParseExact(
            $line.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', $null,
            [System.Globalization.DateTimeStyles]::None, [ref]$ts)
        if (-not $parsed -or $ts -lt $Since) { continue }
        $sawSfcActivity = $true
        if ($line -match 'Cannot repair member file') { $unrepaired = $true }
        elseif ($line -match 'Repairing corrupted file') { $repaired = $true }
    }
    if (-not $sawSfcActivity) { return 'Unknown' }
    if ($unrepaired) { return 'Unrepaired' }
    if ($repaired)   { return 'Repaired' }
    return 'Clean'
}

# --- Relatorio JSON (para RMM/automacao) -------------------------------------

function New-RunReport {
    <#  Monta o relatorio da execucao (tabela ordenada, pronta para
        ConvertTo-Json) a partir do estado atual: $Steps, $StepStatus,
        $StepReport, $RunState, $Simular e $ScriptVersion. #>
    param(
        [datetime]$StartedAt,
        [datetime]$FinishedAt,
        [double]$FreeBefore,
        [double]$FreeAfter,
        [object]$RebootAfter,
        [int]$ExitCode,
        [string]$LogPath
    )
    $osInfo = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $osInfo = [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; isServer = ($os.ProductType -ne 1) }
    } catch {
        Write-Verbose 'Nao foi possivel consultar o sistema operacional para o relatorio.'
    }

    $estimatedBytes = 0L
    $stepItems = @(foreach ($key in $Steps.Keys) {
        $detail = $StepReport[$key]
        $duration = $null; $before = $null; $after = $null; $recovered = $null; $estimated = $null
        if ($detail) {
            $duration  = $detail.DurationSeconds
            $before    = $detail.FreeBeforeGB
            $after     = $detail.FreeAfterGB
            $recovered = [math]::Round($detail.FreeAfterGB - $detail.FreeBeforeGB, 2)
            if ($Simular) {
                $estimated = [math]::Round($detail.EstimatedBytes / 1GB, 3)
                $estimatedBytes += $detail.EstimatedBytes
            }
        }
        [ordered]@{
            id                     = [int]$key
            name                   = $Steps[$key]
            status                 = $StepStatus[$key]
            durationSeconds        = $duration
            freeSpaceBeforeGB      = $before
            freeSpaceAfterGB       = $after
            recoveredGB            = $recovered
            estimatedRecoverableGB = $estimated
        }
    })

    $rebootBefore = $null
    if ($RunState.RebootBefore) { $rebootBefore = [bool]$RunState.RebootBefore.IsPending }
    $estimatedTotal = $null
    if ($Simular) { $estimatedTotal = [math]::Round($estimatedBytes / 1GB, 3) }
    $overall = switch ($ExitCode) { 0 { 'OK' } 1 { 'ALERTA' } default { 'FALHA' } }

    return [ordered]@{
        script                 = 'WindowsOptimizerCleanup'
        version                = $ScriptVersion
        computer               = $env:COMPUTERNAME
        user                   = $env:USERNAME
        os                     = $osInfo
        simulation             = [bool]$Simular
        startedAt              = $StartedAt.ToString('o')
        finishedAt             = $FinishedAt.ToString('o')
        durationSeconds        = [math]::Round(($FinishedAt - $StartedAt).TotalSeconds, 1)
        exitCode               = $ExitCode
        overallStatus          = $overall
        freeSpaceGB            = [ordered]@{ before = $FreeBefore; after = $FreeAfter; recovered = [math]::Round($FreeAfter - $FreeBefore, 2) }
        estimatedRecoverableGB = $estimatedTotal
        sfcStatus              = $RunState.SfcRepairStatus
        rebootPending          = [ordered]@{ beforeServicing = $rebootBefore; afterRun = [bool]$RebootAfter.IsPending; reasons = @($RebootAfter.Reasons) }
        logFile                = $LogPath
        steps                  = $stepItems
    }
}

function Save-RunReport {
    <#  Grava o relatorio em JSON (UTF-8 sem BOM, aceito por qualquer parser).
        $Path pode ser um arquivo ou uma pasta existente (nesse caso o nome e'
        gerado). Retorna o caminho gravado. #>
    param([Parameter(Mandatory)] $Report, [Parameter(Mandatory)] [string]$Path)
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $resolved = Join-Path $resolved ("WindowsOptimizerCleanup_{0}_{1}.json" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    $directory = Split-Path -Parent $resolved
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
    $json = $Report | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($resolved, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $resolved
}

# -----------------------------------------------------------------------------
# INICIO DA EXECUCAO
# -----------------------------------------------------------------------------
Write-Log '==============================================================='
Write-Log ' EXPERTISE TECNOLOGIA - Limpeza e Otimizacao de Windows'
Write-Log " Setor: Tecnologia da Informacao / NOC | Autor: Pablo Fernando Schutz | Versao: $ScriptVersion"
Write-Log '==============================================================='
Write-Log "Computador: $env:COMPUTERNAME | Usuario: $env:USERNAME"
Write-Log "Log salvo em: $LogFile"
if ($Simular) { Write-Log 'MODO SIMULACAO ativo (-Simular): nenhuma alteracao sera feita no sistema.' 'WARN' }
if ($SkipSteps.Count -gt 0) {
    Write-Log ("Passos ignorados via -Pular: {0}" -f ($SkipSteps -join ', '))
    if ($SkipSteps -contains 8 -and $SkipSteps -notcontains 9) {
        Write-Log 'Atencao: o SFC (Passo 9) vai rodar sem o DISM /RestoreHealth (Passo 8) antes, contrariando a recomendacao da Microsoft.' 'WARN'
    }
}

# Pergunta inicial: o operador escolhe se o Passo 1 (PowerShell 7) deve rodar.
# Com -Pular 1 nao ha o que perguntar.
$RunPowerShell7Step = $false
if ($SkipSteps -notcontains 1) { $RunPowerShell7Step = Resolve-PowerShell7Choice -Choice $PowerShell7 }
Write-Log ("Passo 1 (PowerShell 7): {0} (parametro -PowerShell7 = {1})" -f $(if ($RunPowerShell7Step) { 'SIM' } else { 'NAO' }), $PowerShell7)

$FreeBefore = Get-FreeSpaceGB
Write-Log "Espaco livre em $SystemDrive ANTES da limpeza: $FreeBefore GB"

Show-StepMenu -CurrentStep '0'

# -----------------------------------------------------------------------------
# PASSO 1 - VERIFICAR/ATUALIZAR POWERSHELL 7 (OPCIONAL)
# Descricao: Garante que o PowerShell 7 (pwsh) mais recente esteja instalado,
# via MSI oficial em modo silencioso (msiexec /quiet) - o metodo que a propria
# Microsoft recomenda para servidores (o winget nao esta disponivel por padrao
# no Windows Server 2022 ou anterior). So roda se o operador escolher (pergunta
# inicial ou parametro -PowerShell7 Sim).
#
# Decisoes de projeto (ver CONTRIBUTING.md):
# - Nao bloqueia nem interrompe a limpeza: sem internet ou falha na
#   instalacao viram ALERTA no resumo (ver log para detalhes), mas os
#   passos seguintes rodam normalmente.
# - O PowerShell 7 e' instalado lado a lado com o Windows PowerShell 5.1 -
#   o restante deste script continua rodando no mesmo motor que ja estava
#   em uso (nao ha relancamento sob pwsh.exe).
# - O instalador so e' executado se o SHA-256 (quando informado pelo GitHub)
#   conferir e a assinatura Authenticode for valida e da Microsoft.
# - O PS Remoting NAO e' habilitado por padrao (muda a superficie de acesso
#   remoto do servidor); use -HabilitarPSRemoting para habilitar.
# - Em modo simulacao so consulta (somente leitura); nada e' baixado/instalado.
# -----------------------------------------------------------------------------
$Step1SkipReason = if ($RunPowerShell7Step) { '' } else { 'o operador optou por nao verificar/instalar o PowerShell 7 (pergunta inicial, -PowerShell7 Nao ou -Pular 1)' }
Invoke-Step -StepKey '1' -SkipReason $Step1SkipReason -Action {
    $result = Update-PowerShell7 -EnablePSRemoting:$HabilitarPSRemoting -Simulate:$Simular
    if ($result -ne $true) { $StepStatus['1'] = 'ALERTA' }
}

# -----------------------------------------------------------------------------
# PASSO 2 - LIMPEZA DE ARQUIVOS TEMPORARIOS
# Descricao: Remove os arquivos temporarios do usuario atual (%TEMP%),
# de todos os perfis de usuario e do sistema operacional (C:\Windows\Temp).
# Equivalente a: del /q /f /s %TEMP%\*  e  del /q /f /s C:\Windows\Temp\*
#
# Boas praticas / recomendacoes:
# - Rode em janela de manutencao ou fora do horario de pico: em servidores
#   RDS/Terminal Server, usuarios com sessao ativa podem estar usando
#   arquivos dentro do proprio %TEMP%.
# - Arquivos bloqueados (em uso por processos ativos) sao ignorados
#   automaticamente (-ErrorAction SilentlyContinue) e nao interrompem o
#   script - por isso e' normal o espaco recuperado variar entre execucoes.
# - O %TEMP% do processo reflete apenas o perfil que executa o script
#   (normalmente Administrador/SYSTEM); por isso iteramos manualmente por
#   todos os perfis em C:\Users, essencial em servidores multiusuario.
# - Evite rodar durante instalacoes/atualizacoes em andamento (Windows
#   Update, instaladores MSI) para nao remover um temporario em uso por um
#   processo em curso.
# -----------------------------------------------------------------------------
Invoke-Step -StepKey '2' -Action {
    Clear-Folder -Path $env:TEMP -Description 'Temporarios do usuario atual (%TEMP%)'
    Clear-Folder -Path (Join-Path $SystemRoot 'Temp') -Description 'Temporarios do sistema (C:\Windows\Temp)'
    foreach ($profileFolder in (Get-UserProfileFolder)) {
        $userTemp = Join-Path $profileFolder.FullName 'AppData\Local\Temp'
        if (Test-Path -LiteralPath $userTemp) {
            Clear-Folder -Path $userTemp -Description "Temporarios do perfil $($profileFolder.Name)"
        }
    }
}

# -----------------------------------------------------------------------------
# PASSO 3 - CACHE DE NAVEGADORES
# Descricao: Remove o cache de disco dos navegadores mais comuns (Internet
# Explorer, Google Chrome, Mozilla Firefox, Microsoft Edge e Opera) de todos
# os perfis de usuario em C:\Users. Favoritos, senhas e historico nao sao
# afetados - apenas as pastas de cache/Code Cache de cada navegador.
# -----------------------------------------------------------------------------
Invoke-Step -StepKey '3' -Action {
    foreach ($profileFolder in (Get-UserProfileFolder)) {
        Clear-BrowserCache -ProfilePath $profileFolder.FullName -UserName $profileFolder.Name
    }
}

# -----------------------------------------------------------------------------
# PASSO 4 - ESVAZIAR A LIXEIRA DE TODOS OS USUARIOS
# Descricao: Clear-RecycleBin esvazia a Lixeira do usuario que executa o
# script em todas as unidades; em seguida o conteudo de C:\$Recycle.Bin (pastas
# por SID) e' removido para cobrir a Lixeira dos demais usuarios da unidade do
# sistema. Equivalente a: rd /s /q C:\$Recycle.bin
# -----------------------------------------------------------------------------
Invoke-Step -StepKey '4' -Action {
    if ($Simular) {
        Write-Log '[SIMULACAO] Executaria Clear-RecycleBin -Force; o tamanho estimado abaixo cobre as lixeiras de todos os usuarios da unidade do sistema.'
    } else {
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            Write-Log 'Lixeira do usuario atual esvaziada (todas as unidades).'
        } catch {
            Write-Log "Clear-RecycleBin nao esvaziou a Lixeira do usuario atual: $($_.Exception.Message)" 'WARN'
        }
    }
    $recycleRoot = Join-Path $SystemDrive '$Recycle.Bin'
    Get-ChildItem -LiteralPath $recycleRoot -Force -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Clear-Folder -Path $_.FullName -Description "Lixeira da unidade do sistema ($($_.Name))"
    }
}

# -----------------------------------------------------------------------------
# PASSO 5 - LIMPEZA DO CACHE DO WINDOWS UPDATE
# Descricao: Para os servicos de update, limpa C:\Windows\SoftwareDistribution
# \Download (pacotes de update ja instalados/baixados) e restaura os servicos
# ao estado em que estavam (so reinicia o que estava em execucao antes).
# Boa pratica Microsoft para recuperar espaco e corrigir updates corrompidos.
# -----------------------------------------------------------------------------
Invoke-Step -StepKey '5' -Action {
    $downloadCache = Join-Path $SystemRoot 'SoftwareDistribution\Download'
    if ($Simular) {
        Write-Log '[SIMULACAO] Pararia wuauserv/bits, limparia o cache de download e restauraria o estado dos servicos.'
        Clear-Folder -Path $downloadCache -Description 'Cache de download do Windows Update'
        return
    }
    $updateServices = 'wuauserv', 'bits'
    $wasRunning = @()
    foreach ($svc in $updateServices) {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') { $wasRunning += $svc }
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Write-Log "Servico parado: $svc"
    }
    Clear-Folder -Path $downloadCache -Description 'Cache de download do Windows Update'
    foreach ($svc in $updateServices) {
        if ($wasRunning -contains $svc) {
            Start-Service -Name $svc -ErrorAction SilentlyContinue
            Write-Log "Servico reiniciado: $svc"
        } else {
            Write-Log "Servico $svc nao estava em execucao antes do passo; mantido parado."
        }
    }
}

# -----------------------------------------------------------------------------
# PASSO 6 - LIMPEZA DE LOGS E CACHES SECUNDARIOS
# Descricao: Remove relatorios de erro do Windows (WER) e logs/cabinets CBS
# antigos (>30 dias), que podem crescer muito em servidores. O Prefetch so e'
# limpo em Windows Server: no Windows cliente ele acelera a abertura de
# aplicativos e e' autogerenciado pelo sistema (a limpeza so o deixaria mais
# lento ate ser reconstruido, sem ganho relevante de espaco).
# -----------------------------------------------------------------------------
Invoke-Step -StepKey '6' -Action {
    $werRoot = Join-Path $env:ProgramData 'Microsoft\Windows\WER'
    Clear-Folder -Path (Join-Path $werRoot 'ReportQueue')   -Description 'Relatorios de erro (WER - fila)'
    Clear-Folder -Path (Join-Path $werRoot 'ReportArchive') -Description 'Relatorios de erro (WER - arquivo)'

    if (Test-IsServerOS) {
        Clear-Folder -Path (Join-Path $SystemRoot 'Prefetch') -Description 'Arquivos Prefetch'
    } else {
        Write-Log 'Windows cliente detectado: Prefetch preservado (ver Passo 6 no script).'
    }

    $oldCbsLogs = @(Get-ChildItem -LiteralPath (Join-Path $SystemRoot 'Logs\CBS') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.log', '.cab' -and $_.LastWriteTime -lt (Get-Date).AddDays(-30) })
    if ($Simular) {
        $bytes = [long](($oldCbsLogs | Measure-Object -Property Length -Sum).Sum)
        $RunState.SimulatedBytes += $bytes
        Write-Log ("[SIMULACAO] Removeria {0} log(s)/cab(s) CBS com mais de 30 dias - {1:N1} MB" -f $oldCbsLogs.Count, ($bytes / 1MB))
    } else {
        Write-Log 'Removendo logs CBS (.log/.cab) com mais de 30 dias...'
        $oldCbsLogs | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# -----------------------------------------------------------------------------
# VERIFICACAO DE REINICIALIZACAO PENDENTE (antes do servicing)
# Descricao: o DISM (em especial o /StartComponentCleanup) costuma falhar
# enquanto ha reinicializacao pendente. Por isso, antes dos passos 7 a 10, o
# script verifica o estado e avisa - sem interromper (o operador pode nao poder
# reiniciar agora). O resultado tambem vai para o relatorio JSON.
# -----------------------------------------------------------------------------
if (@(7..10 | Where-Object { $SkipSteps -notcontains $_ }).Count -gt 0) {
    $RunState.RebootBefore = Get-PendingReboot
    if ($RunState.RebootBefore.IsPending) {
        Write-Log ("Reinicializacao pendente detectada ANTES do servicing: {0}. O DISM pode falhar ate reiniciar." -f ($RunState.RebootBefore.Reasons -join '; ')) 'WARN'
        $RunState.Notice = 'reinicializacao pendente - o DISM pode falhar ate reiniciar (ver log)'
    } else {
        Write-Log 'Nenhuma reinicializacao pendente antes do servicing.'
    }
    Show-StepMenu -CurrentStep '6'
}

# -----------------------------------------------------------------------------
# PASSO 7 - DISM /AnalyzeComponentStore
# Descricao: Analisa o repositorio de componentes (WinSxS) e informa se a
# limpeza e recomendada e quanto espaco pode ser recuperado.
# -----------------------------------------------------------------------------
Invoke-Step -StepKey '7' -Action {
    $exit = Invoke-DismStep -StepKey '7' -ArgumentList '/Online', '/Cleanup-Image', '/AnalyzeComponentStore'
    Write-Log "DISM AnalyzeComponentStore finalizado. Codigo de saida: $exit"
    if ($exit -ne 0) { $StepStatus['7'] = 'ALERTA' }
}

# -----------------------------------------------------------------------------
# PASSO 8 - DISM /RestoreHealth
# Descricao: Verifica e repara corrupcoes na imagem do Windows usando o
# Windows Update como fonte. Roda ANTES do SFC (recomendacao da Microsoft: o
# DISM fornece os arquivos que o SFC usa para reparar). Requer acesso ao
# Windows Update ou fonte WSUS/ISO.
# -----------------------------------------------------------------------------
Invoke-Step -StepKey '8' -Action {
    $exit = Invoke-DismStep -StepKey '8' -ArgumentList '/Online', '/Cleanup-Image', '/RestoreHealth'
    Write-Log "DISM RestoreHealth finalizado. Codigo de saida: $exit"
    if ($exit -ne 0) {
        $StepStatus['8'] = 'ALERTA'
        if ($RunState.RebootBefore -and $RunState.RebootBefore.IsPending) {
            Write-Log 'O DISM falhou com reinicializacao pendente: reinicie o Sistema Operacional e execute novamente.' 'WARN'
        }
    }
}

# -----------------------------------------------------------------------------
# PASSO 9 - SFC /SCANNOW
# Descricao: O System File Checker verifica a integridade de todos os
# arquivos protegidos do sistema e repara automaticamente os corrompidos
# usando o repositorio de componentes (ja reparado pelo passo anterior). Ao
# final, $RunState.SfcRepairStatus guarda o resultado real (ver
# Get-SfcRepairStatus), usado no relatorio final para so recomendar
# reinicializacao quando fizer sentido.
# -----------------------------------------------------------------------------
Invoke-Step -StepKey '9' -Action {
    if ($Simular) {
        Write-Log '[SIMULACAO] Executaria: sfc.exe /scannow'
        $RunState.SfcRepairStatus = 'Simulated'
        return
    }
    Write-Log 'Executando SFC /scannow...'
    $sfcStart = Get-Date
    $sfc = Start-Process -FilePath 'sfc.exe' -ArgumentList '/scannow' -Wait -PassThru -NoNewWindow
    Write-Log "SFC finalizado. Codigo de saida: $($sfc.ExitCode)"
    if ($sfc.ExitCode -ne 0) { $StepStatus['9'] = 'ALERTA' }

    $RunState.SfcRepairStatus = Get-SfcRepairStatus -Since $sfcStart
    switch ($RunState.SfcRepairStatus) {
        'Clean'      { Write-Log 'SFC nao encontrou/reparou arquivos (confirmado via CBS.log).' }
        'Repaired'   { Write-Log 'SFC reparou arquivos (detectado via CBS.log).' }
        'Unrepaired' {
            Write-Log 'SFC encontrou arquivos corrompidos que NAO conseguiu reparar (ver entradas [SR] no CBS.log).' 'ERRO'
            $StepStatus['9'] = 'ALERTA'
        }
        default      { Write-Log 'Nao foi possivel confirmar o resultado do SFC via CBS.log.' 'WARN' }
    }
}

# -----------------------------------------------------------------------------
# PASSO 10 - DISM /STARTCOMPONENTCLEANUP
# Descricao: Remove versoes antigas e substituidas de componentes do WinSxS,
# reduzindo o tamanho da pasta. Boa pratica Microsoft de manutencao; roda por
# ultimo, depois dos passos de reparo. Diferente da tarefa agendada do Windows,
# o comando nao tem periodo de carencia de 30 dias nem limite de 1 hora.
# Obs: NAO usamos /ResetBase por padrao, pois ele impede a desinstalacao
# de updates ja instalados (descomente abaixo se desejar ganho maximo).
# -----------------------------------------------------------------------------
Invoke-Step -StepKey '10' -Action {
    $exit = Invoke-DismStep -StepKey '10' -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup'
    # $exit = Invoke-DismStep -StepKey '10' -ArgumentList '/Online','/Cleanup-Image','/StartComponentCleanup','/ResetBase'  # <- opcional, ganho maximo, irreversivel
    Write-Log "DISM StartComponentCleanup finalizado. Codigo de saida: $exit"
    if ($exit -ne 0) {
        $StepStatus['10'] = 'ALERTA'
        if ($RunState.RebootBefore -and $RunState.RebootBefore.IsPending) {
            Write-Log 'O StartComponentCleanup falhou com reinicializacao pendente: reinicie o Sistema Operacional e execute novamente.' 'WARN'
        }
    }
}

# -----------------------------------------------------------------------------
# RELATORIO FINAL
# -----------------------------------------------------------------------------
$FinishedAt = Get-Date
$FreeAfter = Get-FreeSpaceGB
$Recovered = [math]::Round($FreeAfter - $FreeBefore, 2)
$RebootAfter = Get-PendingReboot
$ExitCode = Get-ExitCodeFromStatus -Status @($StepStatus.Values)
$OverallName = switch ($ExitCode) { 0 { 'OK' } 1 { 'ALERTA' } default { 'FALHA' } }
$EstimatedBytes = 0L
foreach ($detail in $StepReport.Values) { $EstimatedBytes += $detail.EstimatedBytes }
$EstimatedGB = [math]::Round($EstimatedBytes / 1GB, 2)

Write-Log '==============================================================='
Write-Log ' RELATORIO FINAL'
Write-Log "  Espaco livre ANTES : $FreeBefore GB"
Write-Log "  Espaco livre DEPOIS: $FreeAfter GB"
Write-Log "  Espaco recuperado  : $Recovered GB"
if ($Simular) { Write-Log "  Espaco estimado recuperavel (simulacao): $EstimatedGB GB" }
Write-Log ("  Reinicializacao pendente ao final: {0}" -f $(if ($RebootAfter.IsPending) { 'SIM - ' + ($RebootAfter.Reasons -join '; ') } else { 'NAO' }))
Write-Log "  Codigo de saida    : $ExitCode ($OverallName)"
Write-Log "  Log completo       : $LogFile"
Write-Log '==============================================================='

# Tela final: limpa o console e mostra SO o resumo (nao reexibe o menu de
# passos com numeracao/caixa - isso duplicaria a mesma informacao).
Clear-ConsoleSafe
Write-Host '===============================================================' -ForegroundColor Cyan
Write-Host ' EXPERTISE TECNOLOGIA - WindowsOptimizerCleanup' -ForegroundColor Cyan
Write-Host " Versao: $ScriptVersion | Computador: $env:COMPUTERNAME" -ForegroundColor Cyan
if ($Simular) { Write-Host ' *** MODO SIMULACAO: nenhuma alteracao foi feita no sistema ***' -ForegroundColor Yellow }
Write-Host '===============================================================' -ForegroundColor Cyan
Write-Host ''

Write-Host 'Resumo da execucao:' -ForegroundColor Cyan
foreach ($key in $Steps.Keys) {
    $status = $StepStatus[$key]
    $color = switch ($status) {
        'OK'       { 'Green' }
        'Simulado' { 'Cyan' }
        'ALERTA'   { 'Yellow' }
        'FALHA'    { 'Red' }
        default    { 'DarkGray' }
    }
    Write-Host (Format-StepLine -Label $Steps[$key] -Status $status) -ForegroundColor $color
}
Write-Host ''

Write-Host 'Relatorio final:' -ForegroundColor Cyan
if ($Simular) {
    Write-Host ("  Espaco estimado recuperavel : {0} GB (nada foi removido)" -f $EstimatedGB)
} else {
    Write-Host ("  Espaco livre ANTES  : {0} GB" -f $FreeBefore)
    Write-Host ("  Espaco livre DEPOIS : {0} GB" -f $FreeAfter)
    Write-Host ("  Espaco recuperado   : {0} GB" -f $Recovered)
}
Write-Host ''

# Reinicializacao: so recomendamos de fato quando o SFC comprovadamente
# reparou algo ou o Windows indica reinicializacao pendente. Quando nao da'
# para confirmar o resultado do SFC (CBS.log ausente/ilegivel), erramos para
# o lado seguro e recomendamos mesmo assim.
switch ($RunState.SfcRepairStatus) {
    'Clean' {
        Write-Host 'SFC nao encontrou nem reparou arquivos de sistema.' -ForegroundColor Green
    }
    'Repaired' {
        Write-Host 'SFC reparou arquivos de sistema - recomenda-se reiniciar o Sistema' -ForegroundColor Yellow
        Write-Host 'Operacional em janela de manutencao.' -ForegroundColor Yellow
    }
    'Unrepaired' {
        Write-Host 'ATENCAO: o SFC encontrou arquivos corrompidos que NAO conseguiu reparar,' -ForegroundColor Red
        Write-Host 'mesmo apos o DISM /RestoreHealth. Revise as entradas [SR] do CBS.log' -ForegroundColor Red
        Write-Host '(C:\Windows\Logs\CBS\CBS.log), reinicie o Sistema Operacional e execute' -ForegroundColor Red
        Write-Host 'novamente; se persistir, use uma midia/ISO do Windows como fonte do DISM.' -ForegroundColor Red
    }
    'Unknown' {
        Write-Host 'Nao foi possivel confirmar pelo CBS.log se o SFC reparou arquivos -' -ForegroundColor Yellow
        Write-Host 'por seguranca, recomenda-se reiniciar o Sistema Operacional em' -ForegroundColor Yellow
        Write-Host 'janela de manutencao e revisar o log.' -ForegroundColor Yellow
    }
}
if ($RebootAfter.IsPending) {
    Write-Host 'O Windows indica REINICIALIZACAO PENDENTE:' -ForegroundColor Yellow
    foreach ($reason in $RebootAfter.Reasons) { Write-Host "  - $reason" -ForegroundColor Yellow }
    Write-Host 'Recomenda-se reiniciar o Sistema Operacional em janela de manutencao.' -ForegroundColor Yellow
} else {
    Write-Host 'Nenhuma reinicializacao pendente detectada.' -ForegroundColor Green
}
Write-Host ''
Write-Host ("Codigo de saida: {0} ({1})" -f $ExitCode, $OverallName) -ForegroundColor Cyan
Write-Host 'Concluido.' -ForegroundColor Cyan
Write-Host ''

# -----------------------------------------------------------------------------
# DESTINO DO LOG
# -----------------------------------------------------------------------------
$LogKept = $true
if (Test-InteractiveConsole) {
    $LogKept = Read-YesNo -Prompt "Deseja manter o log salvo em '$LogFile'?" -Default $true
    if (-not $LogKept) {
        Remove-Item -Path $LogFile -Force -ErrorAction SilentlyContinue
        Write-Host 'Log descartado.' -ForegroundColor DarkGray
    } else {
        Write-Host "Log mantido em: $LogFile" -ForegroundColor DarkGray
    }
} else {
    Write-Host "Execucao nao-interativa detectada. Log mantido em: $LogFile" -ForegroundColor DarkGray
}

# -----------------------------------------------------------------------------
# RELATORIO JSON (opcional, -RelatorioJson) E CODIGO DE SAIDA
# O JSON e' gravado depois da decisao sobre o log para refletir se ele foi
# mantido. Falha ao gravar o JSON nao muda o codigo de saida da limpeza.
# -----------------------------------------------------------------------------
if ($RelatorioJson) {
    try {
        $logPathForReport = if ($LogKept) { $LogFile } else { $null }
        $report = New-RunReport -StartedAt $StartedAt -FinishedAt $FinishedAt -FreeBefore $FreeBefore -FreeAfter $FreeAfter `
            -RebootAfter $RebootAfter -ExitCode $ExitCode -LogPath $logPathForReport
        $reportPath = Save-RunReport -Report $report -Path $RelatorioJson
        Write-Host "Relatorio JSON: $reportPath" -ForegroundColor DarkGray
        if ($LogKept) { Write-Log "Relatorio JSON gravado em: $reportPath" }
    } catch {
        Write-Host "Nao foi possivel gravar o relatorio JSON: $($_.Exception.Message)" -ForegroundColor Yellow
        if ($LogKept) { Write-Log "Falha ao gravar o relatorio JSON: $($_.Exception.Message)" 'WARN' }
    }
}

# "exit" so quando ha arquivo (execucao local): em irm | iex ele fecharia o
# console de quem executou. O codigo fica sempre em $LASTEXITCODE.
$global:LASTEXITCODE = $ExitCode
if ($PSCommandPath) { exit $ExitCode }
