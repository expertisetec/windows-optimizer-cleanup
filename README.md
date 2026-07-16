# Optimize-WindowsServer

**Expertise Tecnologia** — Script de limpeza e otimização de Windows Server com boas práticas Microsoft.

- **Autor:** Pablo Fernando Schutz
- **Versão:** 1.0.0

## O que o script faz (em ordem)

1. **Temporários** — limpa `%TEMP%`, `C:\Windows\Temp` e a pasta Temp de todos os perfis de usuário (útil em RDS).
2. **Lixeira** — esvazia `C:\$Recycle.Bin` de todos os usuários.
3. **Cache do Windows Update** — para `wuauserv`/`bits`, limpa `SoftwareDistribution\Download` e reinicia os serviços.
4. **Logs e caches secundários** — WER (relatórios de erro), Prefetch e logs CBS com mais de 30 dias.
5. **`sfc /scannow`** — verifica e repara arquivos de sistema.
6. **`DISM /AnalyzeComponentStore`** — analisa o WinSxS.
7. **`DISM /StartComponentCleanup`** — remove componentes substituídos do WinSxS.
8. **`DISM /RestoreHealth`** — repara a imagem do Windows via Windows Update.

Todos os passos rodam com aprovação automática (sem prompts), geram log em `C:\ExpertiseTI\Logs\` e o script exibe relatório de espaço em disco antes/depois.

## Requisitos

- Windows Server 2016 ou superior (PowerShell 5.1+)
- Executar como **Administrador**
- Acesso ao Windows Update (ou WSUS) para o passo `RestoreHealth`

## Como executar

Localmente:

```powershell
powershell -ExecutionPolicy Bypass -File .\Optimize-WindowsServer.ps1
```

Direto do GitHub (uma linha, para o time de TI):

```powershell
irm https://raw.githubusercontent.com/SEU_USUARIO/optimize-windows-server/main/Optimize-WindowsServer.ps1 | iex
```

> Substitua `SEU_USUARIO` pelo usuário/organização do GitHub após publicar.

## Recomendações

- Execute em **janela de manutenção**: SFC e DISM podem levar de 15 a 60+ minutos e consomem CPU/disco.
- Reinicie o servidor após a execução caso reparos tenham sido aplicados.
- Faça snapshot/backup antes da primeira execução em servidores críticos.
- A opção `DISM /ResetBase` está comentada no script: libera mais espaço, porém impede desinstalar updates já aplicados.

## Licença

Uso interno — Expertise Tecnologia.
