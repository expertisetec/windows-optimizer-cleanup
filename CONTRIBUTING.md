# Contribuindo

Guia rápido para propor mudanças ou novos scripts para a série de automações
de TI / NOC da Expertise Tecnologia.

## Fluxo básico

1. Crie uma branch a partir de `main`.
2. Faça as alterações, testando localmente antes de abrir o PR.
3. Atualize o [CHANGELOG.md](CHANGELOG.md) com a mudança (ver seção
   [Changelog](#changelog) abaixo).
4. Abra um Pull Request para `main` descrevendo o quê e o porquê da mudança.

## Novo script

Todo script novo da série deve nascer a partir dos templates em
[`templates/`](templates/):

- [`templates/Script-Header-Template.ps1`](templates/Script-Header-Template.ps1)
  — cabeçalho padrão (autor, empresa, setor, versão, licença, links).
- [`templates/README-Template.md`](templates/README-Template.md) — README
  padrão do repositório/pasta do script.

Preencha os campos `{{...}}` e mantenha as seções na mesma ordem — isso é o
que garante que todos os scripts da Expertise Tecnologia tenham a mesma cara,
independente de quem escreveu.

## Versionamento (SemVer)

A série segue [Versionamento Semântico](https://semver.org/lang/pt-BR/):
`MAJOR.MINOR.PATCH` (ex.: `1.2.0`).

- **MAJOR** — mudança que quebra compatibilidade: remove um passo existente,
  muda um parâmetro obrigatório, muda comportamento padrão de forma que um
  uso anterior do script passa a se comportar diferente.
- **MINOR** — nova funcionalidade compatível com o uso anterior: novo passo
  de limpeza, novo parâmetro opcional, nova opção de log.
- **PATCH** — correção de bug, ajuste de texto/log, pequena melhoria interna
  que não muda o comportamento observável do script.

Sempre que a versão for incrementada, atualize **os dois lugares** no
script (ver [Fonte única da versão](#fonte-única-da-versão-no-script)), o
badge e a tabela do `README.md`, e registre a mudança no `CHANGELOG.md`.
Os testes (ver [Testes e CI](#testes-e-ci)) falham se algum desses lugares
ficar defasado.

## Fonte única da versão no script

Cada script tem a versão em dois lugares que precisam ficar sincronizados:

1. O campo `Versao` no cabeçalho de comentário (topo do arquivo).
2. A variável `$ScriptVersion` no bloco de configuração inicial.

O campo `$ScriptVersion` é a fonte que o script realmente usa em tempo de
execução (logs, relatório). O cabeçalho existe para leitura humana rápida —
por isso os dois precisam bater. Ao rodar localmente (não via `irm | iex`),
o script confere isso sozinho e emite um aviso (`Write-Warning`) se
divergirem — mas a checagem automática não substitui a atenção ao atualizar
os dois campos juntos ao publicar uma nova versão.

## Changelog

Não documente histórico de versões dentro do próprio `.ps1`. O bloco
`HISTORICO DE VERSOES` do cabeçalho deve apontar para o `CHANGELOG.md` do
repositório, e é lá que cada entrada de versão é detalhada (Adicionado /
Alterado / Corrigido / Removido), seguindo
[Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/).

## Social preview (GitHub)

Depois de incrementar `$ScriptVersion`, rode:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Update-SocialPreview.ps1
```

Isso atualiza a versão exibida em `assets/social-preview-source.html` e
re-renderiza `assets/social-preview.png` (1280×640, requer Chrome ou Edge
instalado). Faça commit do PNG junto com a mudança de versão.

O GitHub **não** tem API para o campo Social Preview — mesmo com o PNG do
repositório atualizado, o passo final continua manual: Settings → General →
Social preview → Edit → Upload an image.

## Testes e CI

Os testes ficam em [`tests/`](tests/) (Pester 5) e o CI em
[`.github/workflows/ci.yml`](.github/workflows/ci.yml), que roda em todo push
para `main` e em todo Pull Request:

1. Verificação de sintaxe no **Windows PowerShell 5.1** (o motor alvo).
2. **PSScriptAnalyzer** com [`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1)
   (falha o CI em qualquer finding de severidade `Error`).
3. **Pester** (`tests/`).

Para rodar localmente:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path .\tests
```

O script **nunca é executado** nos testes (ele limpa o sistema, roda DISM e
SFC): as funções são extraídas via AST e carregadas isoladamente. Ao criar uma
função nova que dê para testar sem efeitos colaterais, acrescente o nome dela à
lista `$functionsUnderTest` no `BeforeAll` do teste e escreva os casos.

Regras que os testes já verificam e que valem para todo script da série:

- **Somente ASCII** no `.ps1` (sem acentos): garante que `irm | iex` e o
  Windows PowerShell 5.1 (que lê arquivos sem BOM como ANSI) não corrompam
  textos.
- Versão idêntica no cabeçalho, em `$ScriptVersion`, no README (badge e tabela)
  e com entrada no `CHANGELOG.md`.

## Convenções para scripts que alteram o sistema

Vale para o `WindowsOptimizerCleanup.ps1` e para os próximos da série:

- **Modo simulação.** Todo passo que altera o sistema deve respeitar `-Simular`
  (alias `-WhatIf`): em simulação registra `[SIMULACAO] ...` no log e não altera
  nada. Consultas somente leitura (ex.: versão no GitHub) são permitidas.
- **Códigos de saída.** `0` = OK, `1` = concluído com ALERTA, `2` = concluído
  com FALHA, `3` = não iniciou (sem elevação ou parâmetro inválido). Grave o
  código em `$LASTEXITCODE` e só use `exit` quando `$PSCommandPath` existir:
  em `irm | iex` o `exit` fecharia o console de quem executou.
- **Estado compartilhado em tabela hash, nunca em `$script:`.** Uma variável
  `$script:x` não chega ao nível superior quando o script roda via
  `& ([scriptblock]::Create(...))`. Use uma tabela hash (ex.: `$RunState`) e
  altere seus itens (`$RunState.Campo = ...`): tipos por referência não
  dependem de escopo. Um teste falha se aparecer `$script:` no script.
- **Relatório para RMM.** `-RelatorioJson` grava um JSON UTF-8 sem BOM com o
  status de cada passo; mantenha o formato compatível ao evoluir (só
  acrescente campos).

## Elevação (Administrador)

O `#Requires -RunAsAdministrator` só é aplicado quando o script roda como
arquivo; em `irm | iex` ele é apenas um comentário. Por isso todo script da
série que precise de privilégio deve conferir a elevação explicitamente no
início (ver `Test-IsAdministrator` em `WindowsOptimizerCleanup.ps1` e o
[template de cabeçalho](templates/Script-Header-Template.ps1)).

## Passos que instalam/alteram software no servidor

O `WindowsOptimizerCleanup.ps1` tem um passo (verificação/atualização do
PowerShell 7) que baixa e instala software a partir da internet. Ele é
**opcional e depende de consentimento do operador**: o script pergunta no
início (ou recebe `-PowerShell7 Sim/Nao`) e, sem console interativo, o padrão
é **não instalar**. As regras para esse tipo de passo são:

- **Consentimento explícito.** Nunca instale nada sem o operador ter escolhido
  (pergunta ou parâmetro). Sem console interativo, o padrão é não instalar.
- **Nunca bloqueie a finalidade principal do script (limpeza):** falha de
  rede/instalação vira `ALERTA` no resumo e o script segue em frente.
- **Valide o que baixou antes de executar:** SHA-256 (quando o fornecedor o
  publica) e assinatura Authenticode válida do fornecedor esperado. Se a
  validação falhar, nada é executado.
- **Não mude a superfície de segurança do servidor por padrão.** Recursos como
  o PS Remoting só são habilitados por parâmetro explícito
  (`-HabilitarPSRemoting`).
- **Instale lado a lado:** o PowerShell 7 não substitui o Windows PowerShell
  5.1 nem força reinicialização do próprio motor do script.

Se um novo script da série precisar de um passo parecido (instalar/atualizar
algo automaticamente), siga o mesmo padrão e documente a decisão aqui.

Sobre o PowerShell 7: a partir da versão 7.7 a Microsoft publica **apenas MSIX**
(sem MSI). O script escolhe a release estável mais recente **que tenha MSI**;
se a série passar a exigir a 7.7 ou superior, será preciso revisar o método de
instalação (MSIX não é uma opção para instalação por máquina em servidores).

Sobre `winget`: **não use** como único mecanismo de instalação nesta série.
A documentação da Microsoft confirma que `winget` não vem por padrão no
Windows Server 2022 ou anterior — que é justamente o público-alvo declarado
destes scripts. Prefira MSI com instalação silenciosa (`msiexec /quiet`),
que é o que a própria Microsoft recomenda para servidores.
