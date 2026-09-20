<div align="center">

# 🧹 WindowsOptimizerCleanup

**Expertise Tecnologia** · Setor de TI / NOC

Script de limpeza e otimização de Windows (Server e Desktop) com boas práticas Microsoft.

[![Versão](https://img.shields.io/badge/vers%C3%A3o-3.0.0-blue)](./CHANGELOG.md)
[![Licença](https://img.shields.io/badge/licen%C3%A7a-Expertise4All-brightgreen)](./LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](#requisitos)

🌐 [Site](https://www.expertise.tec.br/) · 💼 [LinkedIn](https://www.linkedin.com/company/expertisetec/) · 📷 [Instagram](https://www.instagram.com/expertisetec) · 🐙 [GitHub](https://github.com/expertisetec)

</div>

---

| | |
|---|---|
| **Autor**   | Pablo Fernando Schütz |
| **Empresa** | Expertise Tecnologia |
| **Setor**   | TI / NOC |
| **Versão**  | 3.0.0 |
| **Licença** | [Expertise4All](./LICENSE) — uso público e liberado |

---

## O que o script faz (em ordem)

Ao iniciar, o script **pergunta se você quer executar o Passo 1** (PowerShell 7). Todos os demais
passos rodam com aprovação automática (sem prompts).

1. **Verificar/atualizar PowerShell 7 (opcional)** — só roda se você responder **S** à pergunta inicial
   (ou usar `-PowerShell7 Sim`). Consulta a versão estável mais recente **que tenha instalador MSI** no
   GitHub e, se o PowerShell 7 estiver ausente ou desatualizado, baixa o MSI oficial, confere o SHA-256
   (quando o GitHub o informa), exige **assinatura digital válida da Microsoft** e instala em modo
   silencioso. Instala lado a lado com o Windows PowerShell 5.1 e **nunca bloqueia a limpeza**: sem
   internet ou falha na instalação viram apenas um aviso no resumo.
2. **Temporários** — limpa `%TEMP%`, `C:\Windows\Temp` e a pasta Temp de todos os perfis de usuário (útil em RDS).
3. **Cache de navegadores** — limpa o cache dos navegadores mais comuns (Internet Explorer, Google Chrome, Mozilla Firefox, Microsoft Edge e Opera) de todos os perfis de usuário. Favoritos, senhas e histórico não são afetados.
4. **Lixeira** — esvazia a Lixeira do usuário atual (todas as unidades) e o conteúdo de `C:\$Recycle.Bin` de todos os usuários.
5. **Cache do Windows Update** — para `wuauserv`/`bits`, limpa `SoftwareDistribution\Download` e devolve os serviços ao estado em que estavam.
6. **Logs e caches secundários** — WER (relatórios de erro) e logs/cabinets CBS com mais de 30 dias. O Prefetch só é limpo em Windows Server (no Windows cliente ele é preservado).
7. **`DISM /AnalyzeComponentStore`** — analisa o WinSxS.
8. **`DISM /RestoreHealth`** — repara a imagem do Windows via Windows Update.
9. **`sfc /scannow`** — verifica e repara arquivos de sistema. Roda **depois** do DISM, como a Microsoft recomenda (o DISM fornece os arquivos usados no reparo).
10. **`DISM /StartComponentCleanup`** — remove componentes substituídos do WinSxS, por último, depois de qualquer reparo.

Durante a execução, o console mostra um menu fixo com o status de cada passo (`Pendente`, `Executando...`,
`OK`, `ALERTA`, `FALHA`, `Ignorado` ou `Simulado`, com a porcentagem ao vivo nos passos de DISM) em vez de
despejar dezenas de linhas de progresso na tela. Ao final, a tela é limpa e mostra só o resumo da execução,
o relatório de espaço e o código de saída. O log completo é sempre gravado em `C:\Expertise\Logs\` e, ao
final, o script pergunta se você deseja mantê-lo ou descartá-lo.

### Reinicialização pendente

Antes dos passos de DISM (7 a 10) e ao final, o script verifica se o Windows tem **reinicialização pendente**
(CBS, Windows Update, arquivos pendentes de renomear/excluir e troca de nome do computador). Antes do DISM ele
apenas avisa (o `StartComponentCleanup` costuma falhar enquanto há reinicialização pendente) e segue; ao final,
a reinicialização pendente entra na recomendação de reiniciar, junto com o resultado do SFC. O indicador
`PendingFileRenameOperations` também é preenchido por alguns instaladores e antivírus, então trate-o como um
indicador, não como certeza.

### Modo simulação

Com `-Simular` (ou `-WhatIf`) o script **não altera nada**: cada passo registra no log o que faria
(`[SIMULACAO] ...`) e a limpeza de pastas estima quanto espaço seria recuperado. Os comandos de DISM e SFC não
são executados, e o Passo 1 só consulta a versão no GitHub (somente leitura). O resumo mostra o espaço estimado
recuperável e o menu marca os passos como `Simulado`. Só o próprio log (e o JSON, se pedido) é gravado.

### Relatório JSON e códigos de saída (RMM)

Com `-RelatorioJson <arquivo ou pasta>` o script grava um relatório JSON (UTF-8 sem BOM) com versão, máquina,
sistema operacional, modo simulação, horários, espaço livre antes/depois, resultado do SFC, reinicialização
pendente (antes do servicing e ao final) e, **para cada passo**, status, duração e espaço recuperado (ou estimado
na simulação). O espaço por passo é aproximado: outros processos também escrevem em disco durante a execução.

O código de saída fica em `$LASTEXITCODE` e, quando o script roda como arquivo, é também o código de saída do
processo (com `irm | iex` o script **não** usa `exit`, para não fechar o seu console):

| Código | Significado |
|---|---|
| `0` | Concluído sem alertas (passos `OK`, `Ignorado` ou `Simulado`) |
| `1` | Concluído com pelo menos um `ALERTA` (ex.: SFC não reparou, DISM com código diferente de 0, PowerShell 7 não instalado) |
| `2` | Pelo menos um passo com `FALHA` |
| `3` | Não iniciou: sem elevação de Administrador ou parâmetro inválido (`-Pular`) |

Obs.: executado como arquivo por um PowerShell sem elevação, é o próprio PowerShell que recusa (por causa do
`#Requires`) e devolve o código `1`, antes de o script rodar.

## Requisitos

- Windows 10/11 ou Windows Server 2016 ou superior (PowerShell 5.1+)
  - **Windows 10** saiu de suporte em 14/10/2025 (só recebe atualizações com ESU) e o **Windows Server 2016**
    sai do suporte estendido em 12/01/2027 — o script continua funcionando, mas prefira sistemas suportados.
- Executar como **Administrador** — o script confere a elevação ao iniciar e encerra com uma mensagem clara
  se não estiver elevado (inclusive via `irm | iex`, onde o `#Requires` não é aplicado)
- Acesso ao Windows Update (ou WSUS) para o passo `RestoreHealth`
- Acesso à internet (`github.com`) é **opcional** — usado só se você escolher o Passo 1; sem internet, esse
  passo vira um aviso no resumo e o restante da limpeza roda normalmente

## Como executar

Localmente (o script pergunta sobre o PowerShell 7):

```powershell
powershell -ExecutionPolicy Bypass -File .\WindowsOptimizerCleanup.ps1
```

Direto do GitHub (uma linha, para o time de TI):

```powershell
irm https://raw.githubusercontent.com/expertisetec/windows-optimizer-cleanup/main/WindowsOptimizerCleanup.ps1 | iex
```

### Parâmetros (opcionais)

| Parâmetro | Valores | Padrão | O que faz |
|---|---|---|---|
| `-PowerShell7` | `Perguntar`, `Sim`, `Nao` | `Perguntar` | Controla o Passo 1. `Perguntar` pergunta no início; **sem console interativo** (RMM, tarefa agendada) equivale a `Nao`, para nunca instalar software sem consentimento. |
| `-HabilitarPSRemoting` | (chave) | desligado | Habilita o PS Remoting na instalação do PowerShell 7. Só vale se o Passo 1 instalar/atualizar algo. |
| `-Simular` (alias `-WhatIf`) | (chave) | desligado | Não altera nada: registra e estima o que seria feito, inclusive o espaço recuperável. |
| `-Pular` | números de 1 a 10 | nenhum | Ignora passos. Aceita `-Pular 3,6` (também funciona com `-File`). `-Pular 1` dispensa a pergunta do PowerShell 7. |
| `-RelatorioJson` | arquivo ou pasta | nenhum | Grava o relatório JSON. Se for uma pasta existente, o nome do arquivo é gerado. |

Exemplos:

```powershell
# Simulação completa, sem instalar o PowerShell 7 e gravando o relatório em uma pasta
powershell -ExecutionPolicy Bypass -File .\WindowsOptimizerCleanup.ps1 -Simular -PowerShell7 Nao -RelatorioJson C:\Expertise\Relatorios

# Execução real sem o cache de navegadores (3) e sem os logs secundários (6)
powershell -ExecutionPolicy Bypass -File .\WindowsOptimizerCleanup.ps1 -PowerShell7 Nao -Pular 3,6
```

Com `irm | iex` não dá para passar parâmetros; use um scriptblock:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/expertisetec/windows-optimizer-cleanup/main/WindowsOptimizerCleanup.ps1))) -PowerShell7 Nao -Simular
```

## Recomendações

- Execute em **janela de manutenção**: SFC e DISM podem levar de 15 a 60+ minutos e consomem CPU/disco.
- O script só recomenda reiniciar o **Sistema Operacional** quando o SFC realmente reparou algo (confirmado via `CBS.log`); quando não há reparo, informa que a reinicialização não é necessária. Se o SFC encontrar arquivos que **não** consegue reparar (mesmo após o `DISM /RestoreHealth`), o resumo destaca isso e indica os próximos passos.
- Na primeira vez em um cliente ou servidor novo, rode antes com `-Simular` para ver o que seria removido e quanto espaço seria recuperado.
- Ao pular passos, lembre que o SFC (9) foi pensado para rodar depois do `DISM /RestoreHealth` (8); pular só o 8 gera um aviso no log.
- Faça snapshot/backup antes da primeira execução em servidores críticos.
- A opção `DISM /ResetBase` está comentada no script: libera mais espaço, porém impede desinstalar updates já aplicados.
- O PowerShell 7 é instalado **sem** habilitar o PS Remoting (superfície de acesso remoto do servidor). Use `-HabilitarPSRemoting` apenas se você realmente precisar dele.
- Antivírus/EDR podem sinalizar scripts que baixam e instalam software silenciosamente. Se o seu ambiente bloquear o script, execute com `-PowerShell7 Nao` ou libere o arquivo na sua política de segurança.

## Changelog

O histórico de versões fica em [CHANGELOG.md](CHANGELOG.md).

## Contribuindo

Quer propor uma mudança ou criar um novo script para a série? Veja
[CONTRIBUTING.md](CONTRIBUTING.md) — inclui o padrão de cabeçalho, a
convenção de versionamento (SemVer), como rodar os testes e como registrar
mudanças no changelog.

## Licença

Distribuído sob a licença **[Expertise4All](./LICENSE)** — pública e de uso liberado, resultado
dos trabalhos de melhoria contínua e aplicação de boas práticas da Expertise Tecnologia em
ambientes MSP.

## Expertise Tecnologia

Setor de TI / NOC.

🌐 [www.expertise.tec.br](https://www.expertise.tec.br/) · 💼 [LinkedIn](https://www.linkedin.com/company/expertisetec/) · 📷 [Instagram](https://www.instagram.com/expertisetec) · 🐙 [GitHub](https://github.com/expertisetec)
