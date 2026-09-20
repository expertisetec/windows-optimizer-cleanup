# Changelog

Todas as mudanças relevantes deste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/),
e este projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/)
(ver regras em [CONTRIBUTING.md](CONTRIBUTING.md#versionamento-semver)).

## [3.0.0] - 2026-09-20

Versão MAJOR: o script passa a devolver códigos de saída diferentes de 0
(`1` = alertas, `2` = falhas) — antes terminava sempre com 0 —, o que muda o
comportamento observado por agendadores e ferramentas de RMM que tratam código
diferente de 0 como erro.

### Adicionado

- **Verificação de reinicialização pendente** (`Get-PendingReboot`): antes dos
  passos de DISM (7 a 10) o script avisa no menu e no log se há reinicialização
  pendente (CBS, Windows Update, `PendingFileRenameOperations` e troca de nome
  do computador) — o `StartComponentCleanup` costuma falhar nessa condição — e,
  ao final, a reinicialização pendente passa a fazer parte da recomendação de
  reiniciar, junto com o resultado do SFC. Somente leitura; não interrompe.
- **Modo simulação** `-Simular` (alias `-WhatIf`): nada é alterado. Cada passo
  registra no log o que faria (`[SIMULACAO] ...`), a limpeza de pastas estima o
  espaço recuperável (sem contar a mesma pasta duas vezes), DISM e SFC não são
  executados e o Passo 1 só consulta a versão no GitHub. Novo status `Simulado`.
- **Escolha de passos** `-Pular <passos>` (ex.: `-Pular 3,6`): aceita lista
  separada por vírgula, espaço ou ponto e vírgula, inclusive com
  `powershell.exe -File`. Valores fora de 1–10 encerram com código 3. Aviso no
  log ao pular o `RestoreHealth` (8) e rodar o SFC (9).
- **Relatório JSON** `-RelatorioJson <arquivo ou pasta>` (UTF-8 sem BOM): versão,
  máquina, sistema operacional, modo simulação, horários, espaço livre, SFC,
  reinicialização pendente e, por passo, status, duração e espaço recuperado
  (estimado, na simulação).
- **Códigos de saída** para RMM: `0` OK, `1` com ALERTA, `2` com FALHA, `3` não
  iniciou (sem elevação ou parâmetro inválido). Ficam sempre em `$LASTEXITCODE`;
  o `exit` só é usado quando o script roda como arquivo (com `irm | iex` ele
  fecharia o console de quem executou).
- Testes para tudo o que é novo e um teste de regressão que proíbe `$script:` no
  script (ver "Corrigido").

### Alterado

- O resumo final mostra o código de saída e, em simulação, o espaço estimado.
- A pergunta "manter o log?" usa a mesma detecção de console interativo da
  pergunta do PowerShell 7 (`Test-InteractiveConsole`): com entrada
  redirecionada, assume "manter" em vez de tentar ler.
- Sem elevação, o script encerra com código `3` (antes `1`). Quando executado
  como arquivo por um PowerShell sem elevação, quem recusa é o próprio
  `#Requires`, que devolve `1` antes de o script rodar.

### Corrigido

- O estado da execução (resultado do SFC) ficava em variáveis `$script:`, que
  **não chegam ao nível superior** quando o script roda via
  `& ([scriptblock]::Create(...))` — a forma recomendada no README para passar
  parâmetros. Nesse modo o resumo final lia sempre o valor inicial e a
  recomendação sobre o SFC ficava errada. O estado agora vive em uma tabela hash
  compartilhada (`$RunState`), independente de escopo.

## [2.0.0] - 2026-09-20

Versão MAJOR: o comportamento padrão mudou (o PowerShell 7 deixou de ser
instalado implicitamente) e a ordem dos passos de servicing foi alterada.

### Adicionado

- **Pergunta inicial** para o operador escolher se quer executar o Passo 1
  (verificar/instalar/atualizar o PowerShell 7). Padrão: **Não** (Enter).
- Parâmetro `-PowerShell7 <Perguntar|Sim|Nao>` (padrão `Perguntar`) para
  automação. Sem console interativo (RMM, tarefa agendada), `Perguntar`
  equivale a `Nao`: o script nunca instala software sem consentimento.
- Parâmetro `-HabilitarPSRemoting`: habilita o PS Remoting na instalação do
  PowerShell 7 (antes era sempre habilitado, sem estar documentado).
- Verificação de elevação explícita no início — o `#Requires` não é aplicado
  em `irm | iex`, então o script podia rodar sem privilégio e falhar no meio.
- Passo 1: validação de integridade do MSI antes de instalar (SHA-256 quando o
  GitHub informa o digest + assinatura Authenticode válida da Microsoft
  Corporation); instalador rejeitado = nada é executado. Log do `msiexec`
  gravado em `C:\Expertise\Logs\`.
- Passo 1: escolha do MSI conforme a arquitetura (x64, x86 ou ARM64).
- Status `Ignorado` no menu/resumo para o Passo 1 quando o operador recusa.
- SFC: novo resultado `Unrepaired` (arquivos que o SFC **não** conseguiu
  reparar), com aviso destacado no resumo final e status `ALERTA` no passo.
- Testes automatizados (Pester 5) em `tests/`, `PSScriptAnalyzerSettings.psd1`
  e workflow de CI (`.github/workflows/ci.yml`: sintaxe no Windows PowerShell
  5.1, PSScriptAnalyzer e Pester).

### Alterado

- **Ordem dos passos de servicing**, seguindo a recomendação da Microsoft
  (DISM `/RestoreHealth` antes do `sfc /scannow`): 7 `AnalyzeComponentStore`,
  8 `RestoreHealth`, 9 `SFC`, 10 `StartComponentCleanup` (por último, depois de
  qualquer reparo). Antes: SFC, Analyze, StartComponentCleanup, RestoreHealth.
- Passo 1: passa a escolher a release estável mais recente **que tenha MSI**
  (a partir do PowerShell 7.7 a Microsoft só publica MSIX; consultar apenas
  `releases/latest` faria o passo falhar). Download sem barra de progresso
  (mais rápido no Windows PowerShell 5.1).
- Passo 1: o PS Remoting não é mais habilitado por padrão.
- Passo 4 (Lixeira): `Clear-RecycleBin` (usuário atual, todas as unidades)
  **e** limpeza de `C:\$Recycle.Bin` dos demais usuários. Antes o segundo
  método só rodava se o primeiro falhasse, então a Lixeira dos outros usuários
  não era esvaziada apesar do que o README dizia.
- Passo 5 (Windows Update): os serviços `wuauserv`/`bits` só são reiniciados
  se estavam em execução antes do passo (antes eram sempre iniciados).
- Passo 6: o Prefetch só é limpo em Windows Server; no Windows cliente é
  preservado. Logs CBS antigos agora incluem também `.cab` (CbsPersist).
- `Get-SfcRepairStatus` (antes `Test-SfcMadeRepairs`): passa a exigir ao menos
  uma entrada `[SR]` na janela do SFC para afirmar "sem reparo" (antes, um
  CBS.log sem nenhuma entrada da execução era tratado como "nada a reparar").
- Caminhos deixaram de ser fixos em `C:`: usam `%SystemDrive%`, `%SystemRoot%`
  e o diretório de perfis lido do registro.
- `Clear-Folder` remove apenas o link de junctions/symlinks (medida defensiva)
  e usa `-LiteralPath`.
- `Clear-Host` protegido contra hosts sem console (saída redirecionada por
  RMM/agendador).
- Funções renomeadas para o singular (`Get-UserProfileFolder`,
  `Clear-BrowserCache`), conforme as diretrizes do PSScriptAnalyzer.
- README: avisos de fim de suporte (Windows 10 em 14/10/2025; Windows Server
  2016 em 12/01/2027), parâmetros e execução com parâmetros via `irm`.

### Removido

- Limpeza da pasta `WebCache` do Internet Explorer: ela guarda o banco
  `WebCacheV01.dat` (histórico, cookies e dados de sessão), não apenas cache —
  contradizia a promessa de preservar o histórico. Continua limpo o `INetCache`.

## [1.3.0] - 2026-07-17

### Adicionado

- Novo Passo 1: **Verificar/atualizar PowerShell 7**. Consulta a API do
  GitHub pela versão estável mais recente, compara com a versão instalada
  (`pwsh.exe`) e, se ausente ou desatualizada, baixa o MSI oficial e
  instala silenciosamente (`msiexec /quiet`) — o método que a própria
  Microsoft recomenda para servidores (`winget` não está disponível por
  padrão no Windows Server 2022 ou anterior).
- Os passos antigos 1–9 foram renumerados para 2–10 para abrir espaço
  para o novo Passo 1.

### Alterado

- Este passo roda sem confirmação do operador (uso consciente por
  analistas de TI) e **nunca bloqueia a limpeza**: falha de rede, GitHub
  inacessível ou erro na instalação viram `ALERTA` no resumo (detalhes no
  log), mas os passos seguintes rodam normalmente.
- O PowerShell 7 é instalado lado a lado com o Windows PowerShell 5.1 —
  o restante do script continua rodando no mesmo motor que já estava em
  uso (sem relançamento sob `pwsh.exe`).

## [1.2.0] - 2026-07-17

### Adicionado

- Detecção real de reparo do SFC: `Test-SfcMadeRepairs` lê o `CBS.log`
  (tags internas `[SR]`, não localizadas — ao contrário do texto que o
  `sfc.exe` imprime no console) para confirmar se o `/scannow` reparou
  algum arquivo desde o início daquele passo.

### Alterado

- A recomendação de reinicialização no relatório final agora é
  condicional ao resultado real do SFC: só recomenda quando houve reparo
  confirmado; quando não há reparo, informa que não é necessário; quando
  não é possível confirmar (`CBS.log` ausente/ilegível), erra para o
  lado seguro e recomenda mesmo assim.
- A tela final não reexibe mais o menu de passos numerado (que já tinha
  sido mostrado durante a execução) — agora limpa a tela e mostra só o
  resumo final, sem duplicidade.

## [1.1.0] - 2026-07-17

### Adicionado

- Novo passo de limpeza: cache de disco dos navegadores mais comuns
  (Internet Explorer, Google Chrome, Mozilla Firefox, Microsoft Edge e
  Opera), para todos os perfis de usuário em `C:\Users`.
- Menu fixo de passos no console: mostra os 9 passos com status
  (`Pendente`/`Executando...`/`OK`/`ALERTA`/`FALHA`) e a porcentagem ao
  vivo durante os passos de DISM, em vez de despejar dezenas de linhas de
  progresso no terminal.
- Resumo final na tela (status de cada passo + relatório de espaço),
  seguido de uma pergunta ao operador se deseja manter ou descartar o
  arquivo de log.
- Campo `Setor` no cabeçalho do script (acima do `Autor`), passando a ser
  padrão em todos os scripts da série (ver `templates/`).

### Alterado

- `Write-Log` agora grava só no arquivo — a tela é controlada pelo menu de
  passos, para manter o console limpo.
- Mensagem final recomenda reiniciar o **Sistema Operacional** (em vez de
  "o servidor"), já que o script pode rodar em qualquer Windows.
- Passos de DISM passaram a rodar via `Start-Process` com saída
  redirecionada para leitura de porcentagem, em vez de `Tee-Object`
  direto no console (causa da poluição de tela na versão anterior).
- Escopo de compatibilidade ampliado de "Windows Server 2016 ou superior"
  para "Windows 10/11 ou Windows Server 2016 ou superior": nenhum passo do
  script depende de recursos exclusivos de Server, então a declaração de
  requisitos (cabeçalho do script e README) passou a refletir isso.

## [1.0.1] - 2026-07-17

### Alterado

- Renomeado de `Optimize-WindowsServer.ps1` para `WindowsOptimizerCleanup.ps1`
  (padronização de nomenclatura da série de scripts de TI).
- Padronizado o cabeçalho do script e do README (autor, empresa, setor,
  versão, licença Expertise4All e links das plataformas da Expertise
  Tecnologia).

### Adicionado

- Arquivo `LICENSE` (Expertise4All).
- Templates reutilizáveis de README e de cabeçalho de script em `templates/`.

## [1.0.0] - 2026-07-16

### Adicionado

- Versão inicial do script de limpeza e otimização de Windows Server:
  limpeza de temporários, Lixeira e cache do Windows Update; limpeza de
  logs/caches secundários; `sfc /scannow`; e passos de `DISM`
  (`AnalyzeComponentStore`, `StartComponentCleanup`, `RestoreHealth`).
