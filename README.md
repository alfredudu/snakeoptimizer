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
| `cleanup.advanced` | Limpeza avançada: Windows anterior, drivers antigos, lixeiras órfãs, sobras de fabricantes (Dell SupportAssist, HP, Lenovo, NVIDIA, AMD, Intel), logs, caches, pontos de restauração antigos, `$PatchCache$` |
| `cleanup.profiles` | Limpar perfis de usuário: apaga pastas de outros usuários em `C:\Users` (DeleteProfile do Windows, posse, programas que seguram, ao reiniciar) |
| `cleanup.unlock` | Apagar arquivo ou pasta presa (posse, Restart Manager, apagar ao reiniciar) |
| `app.technician` | Área técnica, com senha: resumo das manutenções por e-mail (SMTP) |
| `cleanup.components` | Limpar WinSxS |
| `repair.dism-sfc` | Reparar o Windows (DISM + SFC) |
| `updates.winget` | Atualizar programas (winget) |
| `updates.repair` | Corrigir o Windows Update (cache, downloads presos, políticas que travam a versão nova) |
| `network.repair` | Reparar rede e DNS (IP, DNS, ARP, Winsock, TCP/IP) |
| `network.proxy-reset` | Remover proxy travado |
| `repair.office` | Office e Teams: atualizar, "com problema / não atualiza", cache, login/ativação, reparo rápido ou online, cache do Teams |
| `repair.office-remove` | Remover o Office por completo (mantém os perfis do Outlook e faz backup das personalizações) |
| `repair.office-restore` | Restaurar backup do Office (perfis, assinaturas, modelos, dicionário, autocompletar) |
| `repair.print-spooler` | Destravar a fila de impressão |
| `repair.store` | Redefinir a Microsoft Store |
| `repair.time-sync` | Acertar data e hora |
| `tweaks.recommended` | Aplicar ajustes recomendados |
| `software.backup` | Backup antes de formatar |

### Pelo RMM (agente rodando como SYSTEM)

| Objetivo | Comando |
|---|---|
| Checagem silenciosa com código de saída (0 ok, 1 atenção, 2 crítico, 3 não avaliado) | `$env:SO_MODE='Check'; irm <url>/launch.ps1 \| iex; exit $LASTEXITCODE` |
| Checagem em JSON (para coletar no RMM) | `& ([scriptblock]::Create((irm <url>/launch.ps1))) -Mode Check -Json` |
| Relatório HTML/TXT em `%ProgramData%\SnakeOptimizer\reports` | `$env:SO_MODE='Report'; irm <url>/launch.ps1 \| iex` |
| Abrir a janela na tela do usuário logado | `irm <url>/launch.ps1 \| iex` (detecta SYSTEM e abre na sessão do usuário) |

### Atalho (sem digitar comando)

Baixe o [`Abrir-SnakeOptimizer.cmd`](Abrir-SnakeOptimizer.cmd) e deixe na Área de Trabalho ou no pendrive. Ele pede o Administrador sozinho e abre sempre a versão mais nova.

### Instalar no PC (atualiza sozinho)

```powershell
$env:SO_MODE='Install'; irm links.snaketech.com.br/otimizar | iex
```

Ou pela janela: **Sobre o SnakeOptimizer > Versão nova e instalação no PC**. A instalação deixa:

- uma cópia fixa em `%ProgramData%\SnakeOptimizer\app` (só Administradores alteram);
- a tarefa **`\SnakeOptimizer\Atualizador`** (SYSTEM), que roda 3 minutos depois de ligar o PC e a cada 6 horas. Ela só baixa quando há commit novo na `main` e não troca nada com o SnakeOptimizer aberto (tenta de novo depois). O registro fica em `%ProgramData%\SnakeOptimizer\atualizador.log`;
- o **ícone na bandeja** (perto do relógio) para todos os usuários, pela tarefa `\SnakeOptimizer\Monitor`, que roda ao entrar no Windows e é recriada pelo Atualizador se sumir. Ele que avisa quando o disco enche, a proteção desliga ou falta manutenção, e abre o SnakeOptimizer com um clique. Cada usuário pode desligá-lo na própria conta;
- atalhos **SnakeOptimizer** na Área de Trabalho pública e no Menu Iniciar, que abrem como Administrador e conferem a versão antes de abrir.

O SnakeOptimizer não vira um *serviço* do Windows no sentido estrito: é PowerShell, e um serviço não pode mostrar janela. A tarefa do Agendador como SYSTEM faz esse papel, como no CCleaner e em outros utilitários. Para remover: `$env:SO_MODE='Uninstall'; irm links.snaketech.com.br/otimizar | iex` (mantém relatórios e histórico).

### Manutenção automática

Em **Manutenção > Manutenção automática**: leve de segunda a sábado e completa no domingo (ou só uma das duas), rodando como SYSTEM em segundo plano, sem reiniciar o PC. A tela mostra as últimas execuções e o último relatório.

### Modo silencioso (manutenção pelo RMM, sem janela e sem perguntas)

```powershell
$env:SO_MODE='Run'; $env:SO_TASK='limpeza-rapida,dns'; irm links.snaketech.com.br/otimizar | iex; exit $LASTEXITCODE
```

| Tarefa (`SO_TASK`) | O que faz |
|---|---|
| `ponto-restauracao` | Cria um ponto de restauração |
| `limpeza-rapida` | Temporários, caches e logs (não esvazia a Lixeira) |
| `winsxs` | Limpa o repositório de componentes |
| `dism` / `sfc` / `dism-sfc` | Repara a imagem e os arquivos do Windows |
| `fila-impressao` | Destrava a fila de impressão |
| `hora` | Sincroniza data e hora |
| `atualizacoes` | Instala as atualizações do Windows (sem prévias, versão nova nem drivers opcionais; não reinicia) |
| `dns` | Limpa o cache DNS e ARP e registra o DNS |
| `rede` | Reparo completo de rede (IP, DNS, Winsock, TCP/IP) |
| `discos` | Inventário de discos: % usado de cada unidade, modelo, serial, firmware, interface, saúde, SMART e TRIM (`.txt` em `%ProgramData%\SnakeOptimizer\reports` e na saída do RMM) |
| `verificar` | Salva o relatório completo em `%ProgramData%\SnakeOptimizer\reports` |

Várias tarefas separadas por vírgula rodam sempre na ordem da tabela. Códigos de saída: `0` tudo ok, `1` alguma com aviso, `2` alguma falhou, `3` sem privilégios de administrador, `4` tarefa desconhecida. Sem `SO_TASK`, lista as tarefas.

Como SYSTEM não tem área de trabalho, no modo janela o launcher cria uma tarefa agendada temporária que abre o SnakeOptimizer na sessão do usuário logado (elevada se ele for administrador) e remove a tarefa em seguida. Você acompanha pelo acesso remoto.

### Parâmetros do launcher

| Parâmetro | Variável de ambiente | Descrição |
|---|---|---|
| `-Mode Gui\|Console\|Check\|Report\|Run\|Install\|Update\|Uninstall` | `SO_MODE` | Padrão `Gui` |
| `-Task <tarefas>` | `SO_TASK` | Tarefas do modo `Run` |
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
