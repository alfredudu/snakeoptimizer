# Histórico de mudanças do SnakeOptimizer

## 1.9.15 — 21/11/2026

- **Limpeza avançada > Instalações anteriores do Windows:** a espera pela Limpeza de Disco do Windows ficava muda (até 2 horas) e parecia travada depois que a janelinha dela fechava. Agora a barra mostra há quantos minutos ela trabalha, e se ela ficar 10 minutos parada, sem usar o processador (esperando um disco que não responde, por exemplo), é encerrada e o SnakeOptimizer apaga o que sobrou direto.

## 1.9.14 — 21/11/2026

- **Minimizar vai para a bandeja:** minimizada, a janela sai da barra de tarefas e vira um ícone perto do relógio (um aviso explica isso na primeira vez). Um clique no ícone traz a janela de volta; o botão direito tem **Abrir** e **Fechar**. Uma ação em andamento continua rodando escondida, e se ela precisar de uma resposta o aviso sai do ícone.
- **Monitor da bandeja volta sozinho:** ligado mas fechado (uma atualização o encerrou, ele caiu), o monitor só voltava no próximo logon. Agora a janela do SnakeOptimizer o reabre alguns segundos depois de abrir.

## 1.9.13 — 21/11/2026

- **Saúde dos SSDs NVMe em %:** a Saúde dos discos e o Inventário completo leem o registro de saúde do próprio SSD (o mesmo que o Hard Disk Sentinel e o CrystalDiskInfo usam), em vez de só o resumo do Windows, que costuma vir com o desgaste em 0% e sem horas. Novas linhas: **Saúde** (100% menos a vida útil usada, limitada pela reserva de blocos), **Reserva do SSD**, **Total gravado**, **Ligações**, **Desligamentos bruscos** e **Erros de mídia**, além das horas ligado e da temperatura do próprio disco. Alertas novos: aviso crítico do SSD, reserva no limite e erros de mídia. Exige Administrador.
- **Detalhes técnicos:** os acentos do CHKDSK voltavam a sair trocados ("Estßgio", "concluÝdos") quando o primeiro acento da saída era o "é" de "arquivos é NTFS", que empatava entre as duas codificações. As minúsculas acentuadas passaram a pesar mais na escolha.

## 1.9.12 — 21/11/2026

- **Ignorar programas no winget:** a lista de Atualizar programas (winget), também no Otimizar, ganhou **Ignorar programas**. Os marcados (um driver ODBC, um agente que só atualiza sem Administrador) somem da lista, ficam fora do **Atualizar todos** e deixam de contar como desatualizados no Verificar o PC e no monitor da bandeja. A lista é do PC (`%ProgramData%\SnakeOptimizer\winget-ignorados.json`).
- Nova tela **Atualizações > Programas ignorados no winget**: mostra os ignorados, desde quando, e desmarcar um faz ele voltar a aparecer.

## 1.9.11 — 21/11/2026

- **Área técnica > Importar:** abre a janela "Abrir" do Windows para escolher o `.snakemail` (começa onde já houver um, na Área de Trabalho ou em Downloads), em vez de pedir o caminho digitado.
- **Manutenção automática:** a tela diz de cara se já está agendada ("JÁ ESTÁ AGENDADA e ligada... não precisa fazer nada") e quando é a próxima execução. Ligada, o botão principal é **Manter como está**; a opção atual aparece como **Em uso agora** e as outras como **Trocar para**. Escolher a que já está em uso não refaz nada. Desligada, as opções dizem **Ligar**.
- Os dias do agendamento são lidos também quando o Windows os devolve como máscara (126 = segunda a sábado).

## 1.9.10 — 21/11/2026

- **E-mail com antivírus no meio:** antivírus como o AVG e o Avast interceptam a conexão segura do e-mail e trocam o certificado do servidor; na porta 465 o Windows recusa esse certificado e o envio falhava com "falha na conexão segura (SSL)". Agora, quando a porta configurada falha na conexão, o envio tenta a 2525 e a 587 (STARTTLS) do mesmo servidor. O e-mail de teste salva a porta que funcionou. Uma recusa do servidor (usuário ou senha) não troca de porta.
- A mensagem de erro diz qual antivírus interceptou e quem assinou o certificado recusado.
- **Área técnica:** o quadro "E-mail deste PC" só aparece de novo depois de uma mudança; repetido depois de cada teste, parecia que a tela fechava e abria.

## 1.9.9 — 21/11/2026

- **Área técnica:** o e-mail de teste falhava com "Este host não é conhecido". Na janela, a caixa de cada campo vinha preenchida com "manter: mail.smtp2go.com", e esse "manter:" era gravado junto no servidor, no usuário e no remetente. A caixa agora vem só com o valor, e as configurações já gravadas com o "manter:" são consertadas ao abrir.

## 1.9.8 — 21/11/2026

- **Resumo por e-mail (Área técnica):** no fim do Otimizar, da manutenção automática (e das tarefas do RMM) e, se ligado, das limpezas avulsas, o SnakeOptimizer manda um e-mail com o PC, a duração, o desfecho, o disco antes e depois, o espaço de cada etapa, o que pede atenção e se falta reiniciar. A manutenção automática leva o relatório do PC em anexo. Opção de só enviar quando houver problema.
- **Área técnica**, escondida (só pela busca: "técnico", "smtp") e protegida por senha técnica, além de Administrador. A senha não fica em lugar nenhum: o repositório guarda só o hash dela (`config\tecnico.json`, gerado por `tools\definir-senha-tecnica.ps1`).
- Envio direto por SSL na porta 465 (SMTP2GO por padrão; STARTTLS em 587 e 2525). A configuração fica só no PC (`%ProgramData%\SnakeOptimizer\email.json`, legível só por Administradores e SYSTEM), com a senha do SMTP cifrada pelo Windows. Exportar e importar em arquivo `.snakemail` cifrado com a senha técnica, para configurar outros PCs.
- Modelos dos e-mails em `docs\modelos-email`.
- **Janela:** as perguntas de senha agora mostram pontos em vez do texto.

## 1.9.7 — 21/11/2026

- **Espaço antes e depois, gravado:**
  - **Limpezas e otimizações rodadas sozinhas** (Limpeza rápida, personalizada, avançada, perfis, arquivo preso, WinSxS, Verificar o PC, Acelerar agora e qualquer ação que mude o espaço livre em 50 MB ou mais) terminam com a seção **Espaço no disco do sistema**: antes, depois (com duas casas e a % do disco) e a diferença. Cada uma fica gravada.
  - **Otimizar:** cada etapa mostra o espaço livre de antes e de depois quando ele muda, e o resumo ganhou **Espaço por etapa**, além do antes e depois da execução inteira. Uma atualização que baixou arquivos aparece com sinal de menos.
  - **Histórico de manutenções:** novas seções **Limpezas e otimizações avulsas** (as últimas 10, com antes e depois) e **Espaço por etapa** da última manutenção.
  - **Manutenção automática e RMM:** o resumo e o histórico das execuções trazem o espaço de antes e de depois, e quanto cada tarefa mudou.
- A Liberar memória fica de fora: o que ela libera é RAM, não disco.

## 1.9.6 — 21/11/2026

- **Início:** botão **Descartar** nos avisos da nota de saúde (como "A última manutenção terminou com 1 etapa pedindo atenção"). O aviso some e deixa de descontar da nota até a situação mudar: a próxima manutenção com problema, por exemplo, aparece de novo. Os avisos graves (vírus, antivírus ou firewall desligado, disco quase cheio) não têm o botão.

## 1.9.5 — 21/11/2026

- **Detalhes técnicos:** acentos certos na saída do CHKDSK ("Estágio", "concluídos", "Verificação de índices"). O CHKDSK escreve numa codificação diferente da do DISM, e a leitura usava a do DISM para os dois; agora ela reconhece qual o programa usou. As mensagens de erro dos programas passam pela mesma leitura.

## 1.9.4 — 21/11/2026

- **Limpar perfis de usuário** (Limpeza > Avançado): lista as pastas de `C:\Users` com o tamanho, a conta e o último uso, todas desmarcadas. O seu perfil e o de quem está conectado ficam de fora. Os marcados saem por inteiro, primeiro pelo próprio Windows (que também tira o perfil do registro); o que sobrar sai pelo desbloqueio abaixo. A conta em si não é apagada.
- **Apagar arquivo ou pasta presa** (Limpeza > Avançado), no estilo do Unlocker: cole o caminho e ele toma posse, apaga mesmo com caminho longo, pergunta ao Windows quais programas seguram o arquivo, fecha esses programas e apaga de novo. O que ainda estiver preso (um serviço, o antivírus) fica marcado para o Windows apagar ao reiniciar. Recusa a raiz do disco, a pasta do Windows e o seu perfil.
- **Otimizar:** nova etapa **Atualizar drivers pelo fabricante**, com o Dell Command | Update quando ele está instalado (sem reiniciar). Sem ele, ou num PC de outro fabricante, a etapa é pulada com o nome da ferramenta certa; não é erro.

## 1.9.3 — 21/11/2026

- **Detalhes técnicos:** caixa **Rolar até o fim** ao lado de Copiar, Salvar e Abrir log. Desmarcada, a saída fica parada onde você deixou enquanto a ação roda; marcada de novo, volta ao fim.
- **Otimizar:** a etapa da Microsoft Store saiu. Ela só enviava o pedido e passava adiante, sem mostrar se algo foi atualizado. Continua em Programas, pedida sozinha.
- **Otimizar:** a etapa "Detectar dispositivos e drivers" virou **Detectar dispositivos novos**, que é o que ela faz. A atualização de drivers acontece na etapa do Windows Update.

## 1.9.2 — 21/11/2026

- **Otimizar e manutenção semanal:** o reparo (DISM + SFC) agora vem antes da limpeza de componentes (WinSxS). Com a limpeza primeiro, o serviço de manutenção do Windows ficava com uma checagem pendente e o SFC logo depois levava horas, preso nela.

## 1.9.1 — 21/11/2026

- **Versão nova e instalação no PC:** cada passo da instalação (baixar, trocar a pasta, criar as tarefas, abrir o ícone) aparece na hora. Antes a tela só mostrava a saída no fim e ficava em "Em andamento" sem nenhuma linha, parecendo travada.

## 1.9 — 21/11/2026

- **Limpeza avançada** (Limpeza > Avançado): uma lista com caixas e o tamanho de cada item, só do que existe no PC:
  - **Instalações anteriores do Windows** (Windows.old, `$WINDOWS.~BT`, `$WINDOWS.~WS`, `ESD`), pela Limpeza de Disco do próprio Windows; o que ela deixar sai tomando posse da pasta.
  - **Pacotes de drivers antigos** no DriverStore: fica a versão mais nova de cada driver, e nenhum em uso sai (`pnputil`).
  - **Lixeiras de contas que não existem mais** (`$Recycle.Bin\<SID>` de contas apagadas ou de outro Windows, e a `RECYCLER`), em todos os discos, tomando posse da pasta. A sua Lixeira fica.
  - **Pontos de recuperação do Dell SupportAssist** (`SARemediation`, que chega a dezenas de GB).
  - **Instaladores de drivers dos fabricantes**: Dell, HP (`C:\SWSetup`), Lenovo, NVIDIA, AMD e Intel.
  - **Logs do Windows** (CBS, DISM, Windows Update, instalação, travamentos do kernel).
  - **Caches do Teams, do OneDrive e das miniaturas**, sem perder logins.
  - **Pontos de restauração antigos** (fica o mais recente de cada disco) e o **cache `$PatchCache$`** do Windows Installer.
  - Os itens que tiram uma forma de voltar atrás vêm desmarcados, e o aviso aparece antes de confirmar.
- Manutenção automática completa (semanal) e modo silencioso: tarefa nova `limpeza-avancada`, só com o que não tem nada a perder (logs, instaladores de fabricantes e lixeiras órfãs).
- **SFC com o percentual na tela:** o SFC reescreve "Verificação 9% concluída." na mesma linha, e a janela só recebia a saída dele no fim, parecendo travada por 20 minutos. A saída dos programas agora é lida no momento em que chega, e o percentual aparece nos Detalhes técnicos e na barra. Os acentos do DISM também saem certos.

## 1.8.9 — 21/11/2026

- **Detalhes técnicos sem os vãos em branco:** no DISM, no SFC e nos outros programas com barra de progresso, cada atualização da barra vem com linhas vazias, e as das atualizações escondidas (a tela mostra a barra de 10 em 10%) ficavam: 15 a 20 linhas em branco entre um percentual e o seguinte. Agora, durante a barra, as linhas vazias não aparecem, e fora dela várias seguidas viram uma. Na janela, a barra nova substitui a anterior no mesmo lugar. Vale para todas as telas.

## 1.8.8 — 21/11/2026

- Os cartões das páginas **Manutenção** e **Rede** continuavam pulando de linha. A 1.8.6 ainda dependia de a barra de rolagem estar à vista, e essa informação podia chegar atrasada. Agora a largura sai da área inteira da página, com o espaço da barra sempre reservado, e não depende mais dela.

## 1.8.7 — 21/11/2026

- A janela (canto da barra lateral), o relatório e o backup mostram a versão deste histórico ("Build 1.8.7"). Antes mostravam "Build 3.69", a numeração antiga da base do código.

## 1.8.6 — 21/11/2026

- **Cartões que ficavam pulando de linha** (Início e outras páginas): com a janela perto do limite entre 3 e 4 colunas, a página alternava sozinha entre as duas. A largura era medida sem a barra de rolagem; quando a barra aparecia (por exemplo, no "Atualizando..." do Início), a área estreitava, a página mudava de colunas, a altura mudava, e o ciclo recomeçava. Agora a conta sempre reserva o espaço da barra, e o número de colunas só muda quando a janela muda de tamanho.
- Sai o redesenho forçado da 1.8.5, que tratava como problema de redimensionar a janela o que era esse vaivém.

## 1.8.5 — 21/11/2026

- Janela: ao maximizar, restaurar ou mudar o tamanho, a página se reajusta quando o tamanho para de mudar e é redesenhada inteira. No Início, os atalhos de "Por onde começar" ficavam um por linha, com a largura antiga e espaço sobrando à direita, e cartões antigos deixavam rastro na tela.

## 1.8.4 — 21/11/2026

- **Gerenciar inicialização** mostra direto a lista de tudo o que abre com o Windows, com caixas de marcar: o que abre hoje vem marcado. Desmarque o que não precisa abrir, marque o que quer de volta e clique em **Aplicar**. Antes, a tela perguntava primeiro "Desativar itens" ou "Reativar itens", e a lista só aparecia depois.

## 1.8.3 — 21/11/2026

- **Sem janela preta do ícone da bandeja:** no Windows 11 com o Windows Terminal como terminal padrão, `-WindowStyle Hidden` não esconde o console, e o ícone abria com uma janela do PowerShell que ficava aberta (fechá-la derrubava o ícone). O ícone agora abre pelo `conhost.exe --headless`, que não cria janela, tanto pela tarefa da instalação quanto ao ligar o monitor na própria conta. O Atualizador troca a tarefa antiga e reabre o ícone sozinho.

## 1.8.2 — 21/11/2026

- **Correção do ícone da bandeja que não abria:** quando o Atualizador (SYSTEM) trocava a pasta `app`, ela ficava com as permissões da pasta temporária do SYSTEM, e os usuários não conseguiam ler os arquivos. O ícone falhava ao abrir (resultado -196608), assim como a janela sem elevação. Agora a pasta volta a herdar as permissões de `%ProgramData%\SnakeOptimizer` (usuários leem; só Administradores alteram). As instalações já afetadas são consertadas sozinhas na próxima passada do Atualizador, que reabre o ícone.

## 1.8.1 — 21/11/2026

- Remover o Office por completo: no registro (`HKLM\...\Office`, inclusive `WOW6432Node`), os **suplementos de outros programas** (Teams no Outlook, Adobe Acrobat, antivírus) agora ficam, para continuarem funcionando no Office novo. O resto sai, como antes.
- Uma chave que o Windows não deixa apagar vira "sobra sem efeito na reinstalação", sem "concluído com ressalvas" e sem pedir reinício. Se o Office já não está no PC, a tela diz que pode instalar de novo.

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
