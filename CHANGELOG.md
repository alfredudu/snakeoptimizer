# Histórico de mudanças do SnakeOptimizer

## 1.8 — 21/11/2026

- **Aviso de memória no ícone da bandeja**: com a RAM acima de 90% em 3 leituras seguidas (uns 5 minutos), um balão diz quanto está em uso e qual programa mais ocupa. O clique abre "Liberar memória". Repete no máximo a cada 2 horas; um pico passageiro não avisa.
- Menu do ícone: novo item "Liberar memória".

## 1.7 — 21/11/2026

- O ícone da bandeja (instalação no PC) passa a abrir pela tarefa **`\SnakeOptimizer\Monitor`**, "ao entrar no Windows", para o grupo Usuários e sem elevação, no lugar da entrada em `HKLM\...\Run`. O antivírus (AVG) apagava essa entrada, por ser um PowerShell oculto na inicialização.
- O Atualizador confere a cada execução: se a tarefa do ícone sumiu ou foi desativada, recria e reabre o ícone. As instalações feitas pela 1.5.1 passam sozinhas para a tarefa.

## 1.6 — 20/11/2026

- **Inventário completo de discos** (Diagnóstico > Hardware): cada unidade com barra e % usado, livre e total; cada disco físico com modelo, serial, firmware, tipo (NVMe/SSD/HDD/USB), interface e formato provável, estado, disco de partida/sistema, partições e os contadores SMART (temperatura, desgaste, horas ligado, ligações, erros, total lido e gravado); TRIM. Salva em `.txt` (os 10 mais novos).
- Modo silencioso: tarefa nova `discos`, que também entra na manutenção completa (semanal).

## 1.5.1 — 20/11/2026

- A instalação no PC liga o **ícone na bandeja** (perto do relógio) para todos os usuários e já o abre na hora. Quem desligar o monitor na própria conta (Sobre > Monitor na bandeja) fica de fora, mesmo com a entrada do PC.
- Ao atualizar, o ícone da bandeja é fechado para a troca dos arquivos e reaberto em seguida, já na versão nova. A desinstalação o remove.

## 1.5 — 20/11/2026

- **Instalar no PC com atualização automática** (`-Mode Install`, ou Sobre > Versão nova e instalação no PC): cópia fixa em `%ProgramData%\SnakeOptimizer`, tarefa **Atualizador** (SYSTEM, ao ligar o PC e a cada 6 horas) e atalhos para todos os usuários, que abrem como Administrador. `-Mode Uninstall` remove tudo, menos relatórios e histórico.
- O launcher confere o último commit publicado: se a cópia instalada já é ele, abre sem baixar nada; se não, baixa exatamente esse commit. A troca da pasta é segura (renomeia antes de apagar) e não acontece com o SnakeOptimizer aberto.
- "Verificar nova versão" virou **Versão nova e instalação no PC**: compara a cópia instalada com o GitHub (antes procurava releases, que este repositório não publica).

## 1.4 — 20/11/2026

- **Manutenção automática** (Manutenção): tarefas do Agendador que rodam como SYSTEM, sem janela. Leve (limpeza rápida, DNS, atualizações do Windows e relatório) de segunda a sábado e completa (ponto de restauração, limpeza, WinSxS, DISM + SFC, atualizações, hora, DNS e relatório) no domingo, às 12h; ou só uma das duas. Nunca reinicia o PC. Baixa a versão mais nova a cada execução (sem internet, usa a cópia local). As últimas execuções, com o que pediu atenção e o que pede reinício, aparecem na tela.
- Modo silencioso: tarefas novas `atualizacoes` (sem prévias, versão nova do Windows nem drivers opcionais) e `verificar` (relatório em `%ProgramData%\SnakeOptimizer\reports`). Cada execução fica no histórico (`%ProgramData%\SnakeOptimizer\historico-automatico.json`).
- **`Abrir-SnakeOptimizer.cmd`**: atalho que pede o Administrador sozinho e abre sempre a versão mais nova.
- Segurança: o launcher tranca `%ProgramData%\SnakeOptimizer` para só Administradores e SYSTEM alterarem (a manutenção automática roda o que está lá).
- Correções: andamento detalhado das atualizações, espera quando o Windows já está instalando, janela antiga travada avisa e oferece fechar, reparo do Windows Update segue sem os Serviços de Criptografia.

## 1.3 — 20/11/2026

- **Corrigir o Windows Update** agora também resolve o "fica baixando e nunca termina": cancela os downloads presos na fila do BITS, limpa o cache da Otimização de Entrega e, no fim, pede ao Windows uma busca nova.
- Detecta e explica as políticas que travam o Windows Update ou escondem a versão nova (atualização automática desligada, versão travada, DisableOSUpgrade, adiamento, pausa). Elas aparecem no reparo e na instalação de atualizações, e explicam por que as Configurações dizem "atualizado" enquanto o SnakeOptimizer acha coisas pendentes.

## 1.2 — 20/11/2026

- **Modo silencioso para RMM** (`SO_MODE=Run`, `SO_TASK=...`): limpeza, DISM/SFC, WinSxS, fila de impressão, hora, DNS e rede, sem janela e sem perguntas, com código de saída.
- **Office em níveis** (Reparar o Office): 1 Atualizar; 2 Limpar cache; 3 Office com problema ou não atualiza (limpa o cache, reinicia o serviço do Office, religa-o se estava desativado, força a atualização); 4 Login e ativação; 5 Reparo rápido; 6 Reparo online; 7 Cache do Teams.
- **Remover o Office por completo** agora **mantém os perfis do Outlook**, as assinaturas padrão e a faixa de opções. Antes de remover, guarda um backup na pasta do usuário: registro do Outlook, assinaturas, modelos, dicionário, regras, autocompletar, faixa de opções e um inventário dos .pst/.ost.
- **Restaurar backup do Office** (Reparo): devolve só o que falta, importa os perfis do Outlook se não existirem (ou mescla, se pedido) e confere se os .pst/.ost continuam no lugar.
- Limpeza do cache DNS como tarefa própria.

## 1.1 — 20/11/2026

- **Reparar o Microsoft Office** (Reparo): limpar cache (suplementos e OfficeFileCache), redefinir login e ativação, reparo rápido e reparo online do Clique para Executar. Fecha o Office antes, perguntando.
- **Destravar a fila de impressão** (Reparo): para o Spooler, apaga os trabalhos presos em `spool\PRINTERS` e religa o serviço e os dependentes.
- **Redefinir a Microsoft Store** (Reparo): `wsreset`.
- **Acertar data e hora** (Reparo): liga o serviço de horário se estiver desativado e sincroniza (`w32tm /resync /force`).
- **Remover proxy travado** (Rede): desliga o proxy do usuário e redefine o do sistema (WinHTTP), mostrando os valores antigos.
- Reparo de rede agora também limpa o cache ARP.

## 1.0 — 20/11/2026

- Primeira versão do SnakeOptimizer, da Snake Tech.
- Launcher remoto (`launch.ps1`): roda com um comando (`irm links.snaketech.com.br/otimizar | iex`), abre direto numa ação (`-Action`), faz checagem silenciosa com código de saída para RMM (`-Mode Check`), gera relatório (`-Mode Report`), abre a janela na sessão do usuário quando roda como SYSTEM e confere o SHA-256 do pacote (`-Sha256`).
- Identidade visual da Snake Tech no ícone e no README.
