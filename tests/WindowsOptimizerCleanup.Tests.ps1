#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Testes do WindowsOptimizerCleanup.ps1 (Pester 5).
#
# O script altera o sistema ao ser executado (limpeza, DISM, SFC...), entao ele
# NUNCA e' executado aqui: as funcoes sao extraidas via AST e carregadas
# isoladamente. Execute com:  Invoke-Pester -Path .\tests

BeforeAll {
    $RepoRoot   = Split-Path -Parent $PSScriptRoot
    $ScriptPath = Join-Path $RepoRoot 'WindowsOptimizerCleanup.ps1'

    $tokens = $null
    $parseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)

    # Carrega somente as funcoes exercitadas nos testes. Funcoes que baixam e
    # instalam software (Update-PowerShell7) ficam de fora de proposito: alem de
    # nao serem testaveis sem rede/admin, o texto delas aciona a deteccao de
    # antivirus (AMSI) quando carregado dinamicamente.
    $functionsUnderTest = @(
        'Write-Log', 'Format-StepLine', 'Get-SfcRepairStatus', 'Select-PwshRelease',
        'Get-PwshMsiSuffix', 'Clear-Folder', 'Read-YesNo', 'Resolve-PowerShell7Choice', 'Clear-ConsoleSafe',
        'Test-InteractiveConsole', 'ConvertTo-StepNumberList', 'Get-ExitCodeFromStatus', 'Get-DirectorySizeBytes',
        'Get-PendingReboot', 'New-RunReport', 'Save-RunReport'
    )
    $functionAsts = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { $functionsUnderTest -contains $_.Name }
    foreach ($functionAst in $functionAsts) {
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    # Variaveis que as funcoes esperam encontrar no escopo do script.
    $LogFile     = Join-Path $TestDrive 'teste.log'
    $SystemDrive = 'C:'
    $SystemRoot  = Join-Path $TestDrive 'Windows'
    $Simular     = $false
    $ScriptVersion = '9.9.9'
    $RunState    = @{ SfcRepairStatus = 'NotRun'; SimulatedBytes = 0L; RebootBefore = $null; Notice = '' }

    function New-FakeRelease {
        param([string]$Tag, [string[]]$AssetNames, [bool]$Prerelease = $false, [bool]$Draft = $false, [string]$Digest = $null)
        [pscustomobject]@{
            tag_name   = $Tag
            prerelease = $Prerelease
            draft      = $Draft
            assets     = @($AssetNames | ForEach-Object {
                [pscustomobject]@{
                    name                 = $_
                    browser_download_url = "https://example.invalid/$Tag/$_"
                    digest               = $Digest
                }
            })
        }
    }
}

Describe 'Integridade do script' {
    It 'nao tem erros de sintaxe' {
        $parseErrors.Count | Should -Be 0
    }

    It 'contem apenas caracteres ASCII (seguro para irm | iex e para Windows PowerShell 5.1 sem BOM)' {
        $nonAscii = [System.IO.File]::ReadAllBytes($ScriptPath) | Where-Object { $_ -gt 127 }
        @($nonAscii).Count | Should -Be 0
    }

    It 'tem a versao do cabecalho igual a $ScriptVersion' {
        $header  = Select-String -Path $ScriptPath -Pattern 'Versao\s*:\s*(\S+)' | Select-Object -First 1
        $runtime = Select-String -Path $ScriptPath -Pattern "\`$ScriptVersion\s*=\s*'([\d.]+)'" | Select-Object -First 1
        $header.Matches[0].Groups[1].Value | Should -Be $runtime.Matches[0].Groups[1].Value
    }

    It 'tem a mesma versao no README (badge e tabela) e uma entrada no CHANGELOG' {
        $version   = (Select-String -Path $ScriptPath -Pattern "\`$ScriptVersion\s*=\s*'([\d.]+)'" | Select-Object -First 1).Matches[0].Groups[1].Value
        $readme    = Get-Content -Path (Join-Path $RepoRoot 'README.md') -Raw -Encoding UTF8
        $changelog = Get-Content -Path (Join-Path $RepoRoot 'CHANGELOG.md') -Raw -Encoding UTF8
        $readme    | Should -Match ([regex]::Escape("-$version-blue"))
        $readme    | Should -Match ('\|\s*\*\*Vers.o\*\*\s*\|\s*' + [regex]::Escape($version) + '\s*\|')
        $changelog | Should -Match ('(?m)^## \[' + [regex]::Escape($version) + '\]')
    }

    It 'declara o PowerShell 7 como opcional (parametro -PowerShell7 com padrao Perguntar)' {
        $param = $Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PowerShell7' }
        $param.DefaultValue.Value | Should -Be 'Perguntar'
    }

    It 'declara -Simular (com alias -WhatIf), -Pular e -RelatorioJson' {
        $names = @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        ($names -contains 'Simular')       | Should -BeTrue
        ($names -contains 'Pular')         | Should -BeTrue
        ($names -contains 'RelatorioJson') | Should -BeTrue
        $simular = $Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Simular' }
        $alias = $simular.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' }
        $alias.PositionalArguments[0].Value | Should -Be 'WhatIf'
    }

    It 'nao usa variaveis $script: (nao chegam ao nivel superior quando o script roda via [scriptblock]::Create)' {
        $scoped = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.IsScript }, $true)
        @($scoped).Count | Should -Be 0
    }
}

Describe 'ConvertTo-StepNumberList' {
    It 'aceita lista separada por virgula, espaco ou ponto e virgula, sem repeticao e ordenada' {
        (ConvertTo-StepNumberList -Value '6, 3 3;10') -join ',' | Should -Be '3,6,10'
    }

    It 'aceita varios valores (array)' {
        (ConvertTo-StepNumberList -Value @('3', '6')) -join ',' | Should -Be '3,6'
    }

    It 'retorna lista vazia quando nao ha valor' {
        @(ConvertTo-StepNumberList -Value $null).Count | Should -Be 0
    }

    It 'rejeita numeros fora de 1 a 10 e valores nao numericos' {
        { ConvertTo-StepNumberList -Value '11' } | Should -Throw
        { ConvertTo-StepNumberList -Value '0' }  | Should -Throw
        { ConvertTo-StepNumberList -Value 'x' }  | Should -Throw
    }
}

Describe 'Get-ExitCodeFromStatus' {
    It 'retorna 0 quando tudo esta OK, Ignorado ou Simulado' {
        Get-ExitCodeFromStatus -Status @('OK', 'Ignorado', 'Simulado') | Should -Be 0
    }

    It 'retorna 1 quando ha ALERTA e nenhuma FALHA' {
        Get-ExitCodeFromStatus -Status @('OK', 'ALERTA', 'Ignorado') | Should -Be 1
    }

    It 'retorna 2 quando ha FALHA, mesmo com ALERTA' {
        Get-ExitCodeFromStatus -Status @('ALERTA', 'FALHA', 'OK') | Should -Be 2
    }
}

Describe 'Get-DirectorySizeBytes' {
    It 'soma os arquivos recursivamente e ignora junctions' {
        $root   = Join-Path $TestDrive 'tam'
        $other  = Join-Path $TestDrive 'tam-outro'
        New-Item -ItemType Directory -Path (Join-Path $root 'sub'), $other -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $root 'a.bin'), (New-Object byte[] 10))
        [System.IO.File]::WriteAllBytes((Join-Path $root 'sub\b.bin'), (New-Object byte[] 20))
        [System.IO.File]::WriteAllBytes((Join-Path $other 'grande.bin'), (New-Object byte[] 1000))
        New-Item -ItemType Junction -Path (Join-Path $root 'link') -Target $other | Out-Null

        Get-DirectorySizeBytes -Directory (Get-Item -Path $root) | Should -Be 30
    }
}

Describe 'Clear-Folder em modo simulacao' {
    It 'nao remove nada, soma o tamanho em $RunState e registra [SIMULACAO] no log' {
        $folder = Join-Path $TestDrive 'simular'
        New-Item -ItemType Directory -Path (Join-Path $folder 'sub') -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $folder 'a.bin'), (New-Object byte[] 100))
        [System.IO.File]::WriteAllBytes((Join-Path $folder 'sub\b.bin'), (New-Object byte[] 50))
        $RunState.SimulatedBytes = 0L
        $Simular = $true

        Clear-Folder -Path $folder -Description 'teste de simulacao'

        Test-Path (Join-Path $folder 'a.bin')     | Should -BeTrue
        Test-Path (Join-Path $folder 'sub\b.bin') | Should -BeTrue
        $RunState.SimulatedBytes | Should -Be 150
        (Get-Content -Path $LogFile -Raw) | Should -Match '\[SIMULACAO\] Removeria o conteudo de: teste de simulacao'
    }

    It 'conta a mesma pasta uma vez so, mesmo visitada duas vezes (ex.: %TEMP% do usuario atual e Temp do perfil)' {
        $folder = Join-Path $TestDrive 'contar-uma-vez'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $folder 'a.bin'), (New-Object byte[] 200))
        $RunState.SimulatedBytes = 0L
        $RunState.SimulatedPaths = @{}
        $Simular = $true

        Clear-Folder -Path $folder -Description 'primeira visita'
        Clear-Folder -Path ($folder.ToUpperInvariant() + '\') -Description 'segunda visita (outra grafia do mesmo caminho)'

        $RunState.SimulatedBytes | Should -Be 200
    }
}

Describe 'Get-PendingReboot' {
    It 'retorna IsPending booleano coerente com a lista de motivos' {
        $result = Get-PendingReboot
        ($result.IsPending -is [bool]) | Should -BeTrue
        $result.IsPending | Should -Be (@($result.Reasons).Count -gt 0)
    }
}

Describe 'Relatorio JSON' {
    BeforeAll {
        $Steps      = [ordered]@{ '1' = 'Passo A'; '2' = 'Passo B' }
        $StepStatus = [ordered]@{ '1' = 'OK'; '2' = 'ALERTA' }
        $StepReport = [ordered]@{ '1' = [pscustomobject]@{ DurationSeconds = 1.5; FreeBeforeGB = 10.0; FreeAfterGB = 10.5; EstimatedBytes = 1GB } }
        $RebootAfter = [pscustomobject]@{ IsPending = $true; Reasons = @('Windows Update') }
        $Inicio = [datetime]'2026-09-20 10:00:00'
        $Fim    = [datetime]'2026-09-20 10:02:30'
    }

    It 'monta o relatorio com versao, codigo de saida, passos e reinicializacao' {
        $report = New-RunReport -StartedAt $Inicio -FinishedAt $Fim -FreeBefore 10.0 -FreeAfter 10.5 -RebootAfter $RebootAfter -ExitCode 1 -LogPath 'C:\x.log'
        $report['version']         | Should -Be '9.9.9'
        $report['exitCode']        | Should -Be 1
        $report['overallStatus']   | Should -Be 'ALERTA'
        $report['durationSeconds'] | Should -Be 150
        @($report['steps']).Count  | Should -Be 2
        $report['steps'][0]['recoveredGB']     | Should -Be 0.5
        $report['steps'][1]['durationSeconds'] | Should -BeNullOrEmpty
        $report['rebootPending']['afterRun']   | Should -BeTrue
        $report['freeSpaceGB']['recovered']    | Should -Be 0.5
    }

    It 'so preenche o espaco estimado no modo simulacao' {
        $normal = New-RunReport -StartedAt $Inicio -FinishedAt $Fim -FreeBefore 10.0 -FreeAfter 10.0 -RebootAfter $RebootAfter -ExitCode 0 -LogPath $null
        $normal['simulation']             | Should -BeFalse
        $normal['estimatedRecoverableGB'] | Should -BeNullOrEmpty

        $Simular = $true
        $simulated = New-RunReport -StartedAt $Inicio -FinishedAt $Fim -FreeBefore 10.0 -FreeAfter 10.0 -RebootAfter $RebootAfter -ExitCode 0 -LogPath $null
        $simulated['simulation']             | Should -BeTrue
        $simulated['estimatedRecoverableGB'] | Should -Be 1
    }

    It 'grava JSON valido em UTF-8 sem BOM e permite ler de volta' {
        $report = New-RunReport -StartedAt $Inicio -FinishedAt $Fim -FreeBefore 10.0 -FreeAfter 10.5 -RebootAfter $RebootAfter -ExitCode 1 -LogPath 'C:\x.log'
        $path = Save-RunReport -Report $report -Path (Join-Path $TestDrive 'saida\relatorio.json')

        Test-Path $path | Should -BeTrue
        [System.IO.File]::ReadAllBytes($path)[0] | Should -Not -Be 239
        $parsed = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $parsed.version | Should -Be '9.9.9'
        @($parsed.steps).Count | Should -Be 2
        $parsed.steps[1].status | Should -Be 'ALERTA'
    }

    It 'gera o nome do arquivo quando o caminho e uma pasta existente' {
        $report = New-RunReport -StartedAt $Inicio -FinishedAt $Fim -FreeBefore 10.0 -FreeAfter 10.5 -RebootAfter $RebootAfter -ExitCode 0 -LogPath $null
        $folder = Join-Path $TestDrive 'pasta-relatorios'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null

        $path = Save-RunReport -Report $report -Path $folder

        (Split-Path -Parent $path) | Should -Be $folder
        $path | Should -Match 'WindowsOptimizerCleanup_.+_\d{8}_\d{6}\.json$'
    }
}

Describe 'Format-StepLine' {
    It 'preenche com pontos ate a largura 42' {
        $line = Format-StepLine -Label 'abc' -Status 'OK'
        $line | Should -Be ('  abc ' + ('.' * 39) + ' OK')
    }

    It 'usa dois pontos quando o rotulo ja passa da largura' {
        $label = 'x' * 50
        Format-StepLine -Label $label -Status 'OK' | Should -Be "  $label .. OK"
    }
}

Describe 'Get-SfcRepairStatus' {
    BeforeAll {
        $Since = [datetime]'2026-09-20 10:00:00'
        function Write-CbsLog {
            param([string[]]$Lines)
            $path = Join-Path $TestDrive ('cbs_{0}.log' -f [guid]::NewGuid())
            Set-Content -Path $path -Value $Lines
            return $path
        }
    }

    It 'retorna Unknown quando o CBS.log nao existe' {
        Get-SfcRepairStatus -Since $Since -CbsLogPath (Join-Path $TestDrive 'nao-existe.log') | Should -Be 'Unknown'
    }

    It 'retorna Unknown quando nao ha nenhuma entrada [SR] na janela do SFC' {
        $log = Write-CbsLog -Lines @(
            '2026-09-19 08:00:00, Info                  CSI    00000001 [SR] Verifying 100 components'
            '2026-09-20 10:05:00, Info                  CBS    Outra coisa sem a tag'
        )
        Get-SfcRepairStatus -Since $Since -CbsLogPath $log | Should -Be 'Unknown'
    }

    It 'retorna Clean quando o SFC so verificou' {
        $log = Write-CbsLog -Lines @(
            '2026-09-20 10:05:00, Info                  CSI    00000001 [SR] Verifying 100 components'
            '2026-09-20 10:09:00, Info                  CSI    00000002 [SR] Verify complete'
        )
        Get-SfcRepairStatus -Since $Since -CbsLogPath $log | Should -Be 'Clean'
    }

    It 'retorna Repaired quando o SFC reparou arquivos' {
        $log = Write-CbsLog -Lines @(
            '2026-09-20 10:05:00, Info                  CSI    00000001 [SR] Verifying 100 components'
            '2026-09-20 10:07:00, Info                  CSI    00000002 [SR] Repairing corrupted file [ml:520{260},l:22{11}]"\??\C:\Windows\x.dll" from store'
        )
        Get-SfcRepairStatus -Since $Since -CbsLogPath $log | Should -Be 'Repaired'
    }

    It 'retorna Unrepaired (com prioridade sobre Repaired) quando ha arquivo que nao foi reparado' {
        $log = Write-CbsLog -Lines @(
            '2026-09-20 10:07:00, Info                  CSI    00000002 [SR] Repairing corrupted file [ml:520{260},l:22{11}]"\??\C:\Windows\x.dll" from store'
            '2026-09-20 10:08:00, Info                  CSI    00000003 [SR] Cannot repair member file [l:22{11}]"y.dll" of Microsoft-Windows-Foo, Version = 10.0.1, Culture neutral, PublicKeyToken = 31bf3856ad364e35, ProcessorArchitecture = amd64, versionScope neutral, Type neutral, TypeName neutral, PublicKey neutral in the store, file is missing'
        )
        Get-SfcRepairStatus -Since $Since -CbsLogPath $log | Should -Be 'Unrepaired'
    }

    It 'ignora "Cannot repair" de execucoes anteriores do SFC' {
        $log = Write-CbsLog -Lines @(
            '2026-09-19 08:00:00, Info                  CSI    00000001 [SR] Cannot repair member file [l:22{11}]"y.dll" of Microsoft-Windows-Foo'
            '2026-09-20 10:05:00, Info                  CSI    00000002 [SR] Verify complete'
        )
        Get-SfcRepairStatus -Since $Since -CbsLogPath $log | Should -Be 'Clean'
    }
}

Describe 'Select-PwshRelease' {
    It 'escolhe a release estavel mais recente que tenha MSI' {
        $releases = @(
            New-FakeRelease -Tag 'v7.5.11' -AssetNames 'PowerShell-7.5.11-win-x64.msi'
            New-FakeRelease -Tag 'v7.6.6'  -AssetNames 'PowerShell-7.6.6-win-x64.msi'
            New-FakeRelease -Tag 'v7.4.20' -AssetNames 'PowerShell-7.4.20-win-x64.msi'
        )
        $selected = Select-PwshRelease -Releases $releases -AssetSuffix 'win-x64.msi'
        $selected.Version.ToString() | Should -Be '7.6.6'
        $selected.FileName           | Should -Be 'PowerShell-7.6.6-win-x64.msi'
    }

    It 'ignora previews e rascunhos' {
        $releases = @(
            New-FakeRelease -Tag 'v7.7.0-preview.4' -AssetNames 'PowerShell-7.7.0-preview.4-win-x64.msi' -Prerelease $true
            New-FakeRelease -Tag 'v7.8.0'           -AssetNames 'PowerShell-7.8.0-win-x64.msi' -Draft $true
            New-FakeRelease -Tag 'v7.6.6'           -AssetNames 'PowerShell-7.6.6-win-x64.msi'
        )
        (Select-PwshRelease -Releases $releases -AssetSuffix 'win-x64.msi').Version.ToString() | Should -Be '7.6.6'
    }

    It 'pula releases sem MSI (a partir da 7.7 so existe MSIX)' {
        $releases = @(
            New-FakeRelease -Tag 'v7.7.0' -AssetNames 'PowerShell-7.7.0.msixbundle', 'PowerShell-7.7.0-win-x64.zip'
            New-FakeRelease -Tag 'v7.6.6' -AssetNames 'PowerShell-7.6.6-win-x64.msi'
        )
        (Select-PwshRelease -Releases $releases -AssetSuffix 'win-x64.msi').Version.ToString() | Should -Be '7.6.6'
    }

    It 'seleciona o MSI da arquitetura pedida' {
        $releases = @(New-FakeRelease -Tag 'v7.6.6' -AssetNames 'PowerShell-7.6.6-win-x64.msi', 'PowerShell-7.6.6-win-arm64.msi')
        (Select-PwshRelease -Releases $releases -AssetSuffix 'win-arm64.msi').FileName | Should -Be 'PowerShell-7.6.6-win-arm64.msi'
    }

    It 'extrai o SHA-256 quando o GitHub informa o digest' {
        $hash = 'a' * 64
        $releases = @(New-FakeRelease -Tag 'v7.6.6' -AssetNames 'PowerShell-7.6.6-win-x64.msi' -Digest "sha256:$hash")
        (Select-PwshRelease -Releases $releases -AssetSuffix 'win-x64.msi').Sha256 | Should -Be $hash
    }

    It 'deixa o SHA-256 nulo quando nao ha digest' {
        $releases = @(New-FakeRelease -Tag 'v7.6.6' -AssetNames 'PowerShell-7.6.6-win-x64.msi')
        (Select-PwshRelease -Releases $releases -AssetSuffix 'win-x64.msi').Sha256 | Should -BeNullOrEmpty
    }

    It 'retorna nulo quando nenhuma release serve' {
        $releases = @(New-FakeRelease -Tag 'v7.7.0' -AssetNames 'PowerShell-7.7.0.msixbundle')
        Select-PwshRelease -Releases $releases -AssetSuffix 'win-x64.msi' | Should -BeNullOrEmpty
    }
}

Describe 'Get-PwshMsiSuffix' {
    BeforeEach {
        $savedArch    = $env:PROCESSOR_ARCHITECTURE
        $savedArchW64 = $env:PROCESSOR_ARCHITEW6432
    }
    AfterEach {
        $env:PROCESSOR_ARCHITECTURE  = $savedArch
        $env:PROCESSOR_ARCHITEW6432  = $savedArchW64
    }

    It 'usa x64 para AMD64' {
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'; $env:PROCESSOR_ARCHITEW6432 = $null
        Get-PwshMsiSuffix | Should -Be 'win-x64.msi'
    }

    It 'usa arm64 para ARM64' {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'; $env:PROCESSOR_ARCHITEW6432 = $null
        Get-PwshMsiSuffix | Should -Be 'win-arm64.msi'
    }

    It 'usa x86 para Windows de 32 bits' {
        $env:PROCESSOR_ARCHITECTURE = 'x86'; $env:PROCESSOR_ARCHITEW6432 = $null
        Get-PwshMsiSuffix | Should -Be 'win-x86.msi'
    }

    It 'prioriza PROCESSOR_ARCHITEW6432 (PowerShell 32 bits em Windows 64 bits)' {
        $env:PROCESSOR_ARCHITECTURE = 'x86'; $env:PROCESSOR_ARCHITEW6432 = 'AMD64'
        Get-PwshMsiSuffix | Should -Be 'win-x64.msi'
    }
}

Describe 'Clear-Folder' {
    It 'remove o conteudo e mantem a propria pasta' {
        $folder = Join-Path $TestDrive 'limpar'
        New-Item -ItemType Directory -Path (Join-Path $folder 'sub') -Force | Out-Null
        Set-Content -Path (Join-Path $folder 'a.txt') -Value 'a'
        Set-Content -Path (Join-Path $folder 'sub\b.txt') -Value 'b'

        Clear-Folder -Path $folder -Description 'teste'

        Test-Path $folder | Should -BeTrue
        @(Get-ChildItem -Path $folder -Force).Count | Should -Be 0
    }

    It 'nao segue junctions: remove so o link e preserva o destino' {
        $target = Join-Path $TestDrive 'destino'
        $folder = Join-Path $TestDrive 'com-link'
        New-Item -ItemType Directory -Path $target, $folder -Force | Out-Null
        Set-Content -Path (Join-Path $target 'preservar.txt') -Value 'nao apagar'
        Set-Content -Path (Join-Path $folder 'solto.txt') -Value 'apagar'
        New-Item -ItemType Junction -Path (Join-Path $folder 'link') -Target $target | Out-Null

        Clear-Folder -Path $folder -Description 'teste'

        Test-Path (Join-Path $target 'preservar.txt') | Should -BeTrue
        @(Get-ChildItem -Path $folder -Force).Count | Should -Be 0
    }

    It 'nao falha quando a pasta nao existe' {
        { Clear-Folder -Path (Join-Path $TestDrive 'nao-existe') -Description 'teste' } | Should -Not -Throw
    }
}

Describe 'Read-YesNo' {
    It 'aceita S/Sim como verdadeiro e N/Nao como falso' {
        function Read-Host { 'S' }
        Read-YesNo -Prompt 'ok?' | Should -BeTrue
        function Read-Host { 'nao' }
        Read-YesNo -Prompt 'ok?' -Default $true | Should -BeFalse
    }

    It 'assume o padrao quando a resposta e vazia' {
        function Read-Host { '' }
        Read-YesNo -Prompt 'ok?' -Default $true  | Should -BeTrue
        Read-YesNo -Prompt 'ok?' -Default $false | Should -BeFalse
    }

    It 'pergunta de novo quando a resposta e invalida' {
        $script:respostas = @('talvez', 's')
        function Read-Host {
            $proxima = $script:respostas[0]
            $script:respostas = @($script:respostas | Select-Object -Skip 1)
            return $proxima
        }
        Read-YesNo -Prompt 'ok?' | Should -BeTrue
    }

    It 'assume o padrao quando o host nao permite ler (sem console interativo)' {
        function Read-Host { throw 'sem console' }
        Read-YesNo -Prompt 'ok?' -Default $false | Should -BeFalse
    }
}

Describe 'Resolve-PowerShell7Choice' {
    It 'nao pergunta quando -PowerShell7 Sim' {
        Resolve-PowerShell7Choice -Choice 'Sim' | Should -BeTrue
    }

    It 'nao pergunta quando -PowerShell7 Nao' {
        Resolve-PowerShell7Choice -Choice 'Nao' | Should -BeFalse
    }
}
