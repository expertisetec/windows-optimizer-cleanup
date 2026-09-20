@{
    # Regras desativadas de proposito (ver justificativa em cada linha).
    ExcludeRules = @(
        # A interface do script e' um menu de console colorido; Write-Host e' intencional.
        'PSAvoidUsingWriteHost'
        # Clear-Folder/Update-PowerShell7 sao funcoes internas do script, sem
        # -WhatIf/-Confirm: o script e' de execucao assistida por analista de TI.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
