# Histórico de mudanças do SnakeOptimizer

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
