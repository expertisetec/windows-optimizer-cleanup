<#
===============================================================================
  EXPERTISE TECNOLOGIA
===============================================================================
  Script  : Optimize-WindowsServer.ps1
  Descricao : Limpeza e otimizacao de Windows Server com aplicacao de
              boas praticas Microsoft (temporarios, Lixeira, cache do
              Windows Update, SFC e DISM), com log e relatorio de espaco.
  Autor   : Pablo Fernando Schutz
  Empresa : Expertise Tecnologia
  Versao  : 1.0.0
  Data    : 16/07/2026
  Requisitos: Windows Server 2016 ou superior | PowerShell 5.1+
              Executar como Administrador
  Uso     : powershell -ExecutionPolicy Bypass -File .\Optimize-WindowsServer.ps1
===============================================================================
  HISTORICO DE VERSOES
  1.0.0 - 16/07/2026 - Pablo F. Schutz - Versao inicial
===============================================================================
#>

#Requires -RunAsAdministrator

# -----------------------------------------------------------------------------
# CONFIGURACAO INICIAL E LOG
# -----------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'
$ScriptVersion = '1.0.0'
$LogDir  = 'C:\ExpertiseTI\Logs'
$LogFile = Join-Path $LogDir ("Optimize-WindowsServer_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

function Get-FreeSpaceGB {
    [math]::Round((Get-PSDrive -Name C).Free / 1GB, 2)
}

function Clear-Folder {
    <#  Remove o CONTEUDO de uma pasta de forma segura (a pasta em si e mantida).
        Arquivos em uso sao ignorados sem interromper o script. #>
    param([string]$Path, [string]$Description)
    if (Test-Path $Path) {
        Write-Log "Limpando: $Description ($Path)"
        Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log "Pasta nao encontrada, ignorando: $Path" 'WARN'
    }
}

Write-Log '==============================================================='
Write-Log ' EXPERTISE TECNOLOGIA - Limpeza e Otimizacao de Windows Server'
Write-Log " Autor: Pablo Fernando Schutz | Versao: $ScriptVersion"
Write-Log '==============================================================='
Write-Log "Servidor: $env:COMPUTERNAME | Usuario: $env:USERNAME"
Write-Log "Log salvo em: $LogFile"

$FreeBefore = Get-FreeSpaceGB
Write-Log "Espaco livre em C: ANTES da limpeza: $FreeBefore GB"

# -----------------------------------------------------------------------------
# PASSO 1 - LIMPEZA DE ARQUIVOS TEMPORARIOS
# Descricao: Remove os arquivos temporarios do usuario atual (%TEMP%),
# de todos os perfis de usuario e do sistema operacional (C:\Windows\Temp).
# Equivalente a: del /q /f /s %TEMP%\*  e  del /q /f /s C:\Windows\Temp\*
# -----------------------------------------------------------------------------
Write-Log '--- PASSO 1: Limpeza de arquivos temporarios ---'
Clear-Folder -Path $env:TEMP -Description 'Temporarios do usuario atual (%TEMP%)'
Clear-Folder -Path 'C:\Windows\Temp' -Description 'Temporarios do sistema (C:\Windows\Temp)'

# Temporarios de todos os perfis (util em servidores RDS/Terminal Server)
Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $userTemp = Join-Path $_.FullName 'AppData\Local\Temp'
    if (Test-Path $userTemp) {
        Clear-Folder -Path $userTemp -Description "Temporarios do perfil $($_.Name)"
    }
}

# -----------------------------------------------------------------------------
# PASSO 2 - ESVAZIAR A LIXEIRA DE TODOS OS USUARIOS
# Descricao: Remove o conteudo de C:\$Recycle.Bin (Lixeira) de todas as
# unidades. Equivalente a: rd /s /q C:\$Recycle.bin
# -----------------------------------------------------------------------------
Write-Log '--- PASSO 2: Esvaziando a Lixeira ---'
try {
    Clear-RecycleBin -Force -ErrorAction Stop
    Write-Log 'Lixeira esvaziada com sucesso.'
} catch {
    Write-Log "Clear-RecycleBin indisponivel, usando metodo alternativo: $($_.Exception.Message)" 'WARN'
    Remove-Item 'C:\$Recycle.Bin\*' -Recurse -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# PASSO 3 - LIMPEZA DO CACHE DO WINDOWS UPDATE
# Descricao: Para os servicos de update, limpa C:\Windows\SoftwareDistribution
# \Download (pacotes de update ja instalados/baixados) e reinicia os servicos.
# Boa pratica Microsoft para recuperar espaco e corrigir updates corrompidos.
# -----------------------------------------------------------------------------
Write-Log '--- PASSO 3: Limpeza do cache do Windows Update ---'
$updateServices = 'wuauserv', 'bits'
foreach ($svc in $updateServices) { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue; Write-Log "Servico parado: $svc" }
Clear-Folder -Path 'C:\Windows\SoftwareDistribution\Download' -Description 'Cache de download do Windows Update'
foreach ($svc in $updateServices) { Start-Service -Name $svc -ErrorAction SilentlyContinue; Write-Log "Servico iniciado: $svc" }

# -----------------------------------------------------------------------------
# PASSO 4 - LIMPEZA DE LOGS E CACHES SECUNDARIOS
# Descricao: Remove relatorios de erro do Windows (WER), arquivos Prefetch
# e logs CBS antigos (>30 dias), que podem crescer muito em servidores.
# -----------------------------------------------------------------------------
Write-Log '--- PASSO 4: Limpeza de logs e caches secundarios ---'
Clear-Folder -Path 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue'   -Description 'Relatorios de erro (WER - fila)'
Clear-Folder -Path 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive' -Description 'Relatorios de erro (WER - arquivo)'
Clear-Folder -Path 'C:\Windows\Prefetch' -Description 'Arquivos Prefetch'

Write-Log 'Removendo logs CBS com mais de 30 dias...'
Get-ChildItem 'C:\Windows\Logs\CBS' -Filter '*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# PASSO 5 - SFC /SCANNOW
# Descricao: O System File Checker verifica a integridade de todos os
# arquivos protegidos do sistema e repara automaticamente os corrompidos
# usando o repositorio local (WinSxS).
# -----------------------------------------------------------------------------
Write-Log '--- PASSO 5: SFC /scannow (verificacao de integridade de arquivos) ---'
Write-Log 'Executando SFC. Isso pode levar varios minutos...'
$sfc = Start-Process -FilePath 'sfc.exe' -ArgumentList '/scannow' -Wait -PassThru -NoNewWindow
Write-Log "SFC finalizado. Codigo de saida: $($sfc.ExitCode)"

# -----------------------------------------------------------------------------
# PASSO 6 - DISM /AnalyzeComponentStore
# Descricao: Analisa o repositorio de componentes (WinSxS) e informa se a
# limpeza e recomendada e quanto espaco pode ser recuperado.
# -----------------------------------------------------------------------------
Write-Log '--- PASSO 6: DISM /Online /Cleanup-Image /AnalyzeComponentStore ---'
dism.exe /Online /Cleanup-Image /AnalyzeComponentStore | Tee-Object -FilePath $LogFile -Append

# -----------------------------------------------------------------------------
# PASSO 7 - DISM /StartComponentCleanup
# Descricao: Remove versoes antigas e substituidas de componentes do WinSxS,
# reduzindo o tamanho da pasta. Boa pratica Microsoft de manutencao.
# Obs: NAO usamos /ResetBase por padrao, pois ele impede a desinstalacao
# de updates ja instalados (descomente abaixo se desejar ganho maximo).
# -----------------------------------------------------------------------------
Write-Log '--- PASSO 7: DISM /Online /Cleanup-Image /StartComponentCleanup ---'
dism.exe /Online /Cleanup-Image /StartComponentCleanup | Tee-Object -FilePath $LogFile -Append
# dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase   # <- opcional, ganho maximo, irreversivel

# -----------------------------------------------------------------------------
# PASSO 8 - DISM /RestoreHealth
# Descricao: Verifica e repara corrupcoes na imagem do Windows usando o
# Windows Update como fonte. Complementa o SFC (repara o proprio repositorio
# que o SFC usa). Requer acesso ao Windows Update ou fonte WSUS/ISO.
# -----------------------------------------------------------------------------
Write-Log '--- PASSO 8: DISM /Online /Cleanup-Image /RestoreHealth ---'
Write-Log 'Executando RestoreHealth. Pode demorar bastante e requer acesso ao Windows Update...'
dism.exe /Online /Cleanup-Image /RestoreHealth | Tee-Object -FilePath $LogFile -Append

# -----------------------------------------------------------------------------
# RELATORIO FINAL
# -----------------------------------------------------------------------------
$FreeAfter = Get-FreeSpaceGB
$Recovered = [math]::Round($FreeAfter - $FreeBefore, 2)
Write-Log '==============================================================='
Write-Log ' RELATORIO FINAL'
Write-Log "  Espaco livre ANTES : $FreeBefore GB"
Write-Log "  Espaco livre DEPOIS: $FreeAfter GB"
Write-Log "  Espaco recuperado  : $Recovered GB"
Write-Log "  Log completo       : $LogFile"
Write-Log ' Concluido. Recomenda-se reiniciar o servidor em janela de manutencao'
Write-Log ' caso o SFC/DISM tenha reparado arquivos.'
Write-Log '==============================================================='
