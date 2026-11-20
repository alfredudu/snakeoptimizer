<p align="center">
  <img src="assets/SnakeOptimizer.png" width="200" height="200" alt="Logo da Snake Tech">
</p>

# SnakeOptimizer

O **SnakeOptimizer** é a ferramenta de manutenção, diagnóstico e otimização do Windows usada pela **Snake Tech**. Roda em PowerShell, com interface gráfica e menu de terminal, e pode ser chamado direto da internet com um comando — sem instalar nada no cliente.

## Rodar no cliente com um comando

Abra o **PowerShell como Administrador** (ou use o terminal remoto do seu RMM / ScreenConnect / AnyDesk) e cole:

```powershell
irm https://raw.githubusercontent.com/alfredudu/snakeoptimizer/main/launch.ps1 | iex
```

O launcher baixa a versão atual do repositório para `%ProgramData%\SnakeOptimizer\app` e abre a janela.

### Abrir direto numa otimização específica

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/alfredudu/snakeoptimizer/main/launch.ps1))) -Action performance.boost
```

Ou, mantendo o formato `irm | iex` (bom para RMM que aceita só uma linha):

```powershell
$env:SO_ACTION='cleanup.quick'; irm https://raw.githubusercontent.com/alfredudu/snakeoptimizer/main/launch.ps1 | iex
```

Ações mais usadas (lista completa com `-ListActions`):

| Ação | O que faz |
|---|---|
| `maintenance.recommended` | Otimizar (manutenção recomendada) |
| `maintenance.checkup` | Verificar o PC |
| `performance.boost` | Acelerar agora |
| `cleanup.quick` | Limpeza rápida |
| `cleanup.components` | Limpar WinSxS |
| `repair.dism-sfc` | Reparar o Windows (DISM + SFC) |
| `updates.winget` | Atualizar programas (winget) |
| `updates.repair` | Corrigir o Windows Update |
| `network.repair` | Reparar rede e DNS |
| `tweaks.recommended` | Aplicar ajustes recomendados |
| `software.backup` | Backup antes de formatar |

### Pelo RMM (agente rodando como SYSTEM)

| Objetivo | Comando |
|---|---|
| Checagem silenciosa com código de saída (0 ok, 1 atenção, 2 crítico, 3 não avaliado) | `$env:SO_MODE='Check'; irm <url>/launch.ps1 \| iex; exit $LASTEXITCODE` |
| Checagem em JSON (para coletar no RMM) | `& ([scriptblock]::Create((irm <url>/launch.ps1))) -Mode Check -Json` |
| Relatório HTML/TXT em `%ProgramData%\SnakeOptimizer\reports` | `$env:SO_MODE='Report'; irm <url>/launch.ps1 \| iex` |
| Abrir a janela na tela do usuário logado | `irm <url>/launch.ps1 \| iex` (detecta SYSTEM e abre na sessão do usuário) |

Como SYSTEM não tem área de trabalho, no modo janela o launcher cria uma tarefa agendada temporária que abre o SnakeOptimizer na sessão do usuário logado (elevada se ele for administrador) e remove a tarefa em seguida. Você acompanha pelo acesso remoto.

### Parâmetros do launcher

| Parâmetro | Variável de ambiente | Descrição |
|---|---|---|
| `-Mode Gui\|Console\|Check\|Report` | `SO_MODE` | Padrão `Gui` |
| `-Action <id>` | `SO_ACTION` | Item que a janela executa ao abrir |
| `-Page <página>` | `SO_PAGE` | Página inicial (`cleanup`, `repair`, `network`...) |
| `-Json` | — | Saída JSON no modo `Check` |
| `-Source <url do zip>` | `SO_SOURCE` | Baixa de outro lugar (release, servidor próprio) |
| `-Sha256 <hash>` | `SO_SHA256` | Só executa se o zip bater com o hash |
| `-NoUpdate` | — | Usa a cópia local sem baixar de novo |
| `-InUserSession` | — | Força abrir na sessão do usuário logado |
| `-ListActions` | — | Lista todas as ações disponíveis |

### Configuração (uma vez)

1. Crie o repositório no seu GitHub (ex.: `snakeoptimizer`) e envie este código.
2. Troque `alfredudu/snakeoptimizer` pelo seu `usuario/repositorio` em:
   - `launch.ps1` (variável `$Repository`)
   - `modules/AppUpdate.psm1` (função `Get-SnakeOptimizerRepository`)
   - este README
3. Link curto no YOURLS (`links.snaketech.com.br`): encurte **só a URL** `https://raw.githubusercontent.com/alfredudu/snakeoptimizer/main/launch.ps1` com a palavra `otimizar`. O YOURLS responde com redirecionamento direto (301), que o `irm` segue sozinho, e o comando vira:

   ```powershell
   irm links.snaketech.com.br/otimizar | iex
   ```

   Sem abrir o PowerShell antes: **Win+R** → `powershell -ep bypass -c "irm links.snaketech.com.br/otimizar|iex"`.

O repositório precisa ser **público** para o `irm` funcionar sem credencial. Não coloque token de acesso no comando: ele ficaria gravado nos logs do RMM e do PowerShell do cliente.

## O que você pode fazer

- **Diagnosticar o PC:** informações do Windows, hardware, discos, rede, bateria e proteção.
- **Cuidar do sistema:** verificação do PC, manutenção guiada e reparo com DISM, SFC e CHKDSK.
- **Liberar espaço:** análise de armazenamento, limpeza, arquivos duplicados e atalhos quebrados.
- **Gerenciar programas:** instalar, atualizar e remover aplicativos com winget e revisar a inicialização.
- **Atualizar o Windows:** atualizações e drivers disponíveis, com acompanhamento pela interface.
- **Segurança:** estado da proteção e verificações do Windows Defender.
- **Personalizar o Windows:** ajustes com opção de reversão.
- **Histórico:** relatórios, mudanças, manutenção agendada e monitor na bandeja.

Algumas operações alteram configurações ou removem arquivos; confira as opções antes de executá-las.

## Requisitos

- Windows 10 ou 11, Windows PowerShell 5.1 (já incluso).
- Administrador para funções que alteram o sistema.
- [winget](https://learn.microsoft.com/pt-br/windows/package-manager/winget/) para gerenciar programas.
- Internet para downloads e recursos online.

## Uso local (sem o launcher)

Baixe/extraia a pasta inteira e abra **SnakeOptimizer.cmd** (janela) ou **SnakeOptimizer-Console.cmd** (terminal).

```powershell
.\SnakeOptimizer-Console.cmd -Action Check        # verificação rápida
.\SnakeOptimizer-Console.cmd -Action Check -Json  # saída em JSON
.\SnakeOptimizer-Console.cmd -Action Report       # relatório HTML e texto
```

## Segurança e dados

- **Permissões:** limpeza, reparo, atualização e ajustes alteram o sistema; nem tudo pode ser desfeito.
- **Inicialização:** os lançadores usam `ExecutionPolicy Bypass` só no processo e desbloqueiam os arquivos baixados da pasta do app.
- **Assinatura:** os scripts não são assinados. Para reduzir alertas do Defender/SmartScreen, assine com `tools\Sign-SnakeOptimizer.ps1` e um certificado de assinatura de código.
- **Dados locais:** logs, relatórios e estado ficam em `%LOCALAPPDATA%\SnakeOptimizer`. Podem conter informações do computador.
- **Backup antes de formatar:** não copia arquivos pessoais. Se incluir redes Wi-Fi, as senhas ficam em texto puro.

## Licença

Distribuído sob a licença [GNU GPLv3](LICENSE).

© 2026 Snake Tech. Contém código © 2026 Guilherme Henn, modificado pela Snake Tech.
