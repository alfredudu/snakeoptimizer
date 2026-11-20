# Histórico de mudanças do SnakeOptimizer

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
