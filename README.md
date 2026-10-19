# Insight Notch

Uma central de produtividade para macOS, baseada no [Boring Notch](https://github.com/TheBoredTeam/boring.notch) 2.7.3. Reúne mídia, arquivos, clipboard, atividade, uso de IA, dispositivos móveis e computadores remotos no painel do notch.

Este README usa somente papéis genéricos, caminhos relativos e domínios de exemplo. Nenhuma chave, pareamento, conta, nome de equipamento ou configuração de rede pessoal é necessária para ler ou compartilhar estas instruções.

## Recursos implementados

| Área | O que oferece |
| --- | --- |
| Home e mídia | Reprodução do macOS, capa, controles, calendário e recursos herdados de HUD, espelho e carregamento. |
| Shelf | Arrastar e soltar arquivos, compartilhamento e integração com AirDrop. |
| Clipboard | Histórico pesquisável, itens fixados e limpeza dos não fixados; `Control+V` abre o histórico e `Command+V` mantém a colagem normal. Conteúdo marcado como confidencial é ignorado. |
| Links | Captura de URL HTTP/HTTPS com título e observação opcionais, salva como Markdown em uma caixa de entrada do Obsidian. |
| Atividade | Eventos locais de tarefas, transferências e aplicativos, com estados de progresso e conclusão. A integração com Dot pode ser ocultada nas configurações sem removê-la. |
| Uso de IA | Janelas de uso de Claude, Codex e Gemini; histórico, fontes locais adicionais de OpenCode e estimativas quando disponíveis. Indica leituras antigas em vez de tratá-las como atuais. |
| Avisos de limites | Alertas em 80% e 95%, com deduplicação e respeito à janela de renovação. Comparações relativas e dados antigos não geram avisos de cota. |
| Mixer | Volume e mute por aplicativo, integrados ao painel, além dos controles de áudio existentes. |
| Prévia de janelas | Prévia ao interagir com o Dock, com fallback para ícone quando a captura não estiver disponível. |
| Dispositivos móveis | Bateria, carregamento, toque de localização, compartilhamento e transferências pelo KDE Connect. |
| Mensagens | Notificações encaminhadas para as notificações nativas do macOS e resposta pelo painel quando a origem oferece uma ação de resposta. |
| Mídia remota | Seleção de player e ações anterior, reproduzir/pausar e próxima para players expostos pelo KDE Connect. |
| Arquivos | Cópias acompanhadas, busca por nome em raízes permitidas e obtenção de arquivos de computadores remotos. |
| Processamento | Filas persistentes por destino para converter vídeo em MP4, extrair áudio M4A e transcrever localmente. Progresso, cancelamento e verificação SHA-256 do resultado. |
| Mesa contínua | Compartilhamento de teclado, mouse e clipboard com Deskflow, disposição lateral e túneis SSH privados. |
| Apps Android | Espelhamento e aplicativos em janelas com scrcpy, listagem de apps, ícones extraídos do aparelho e encerramento das janelas sem manter seus itens temporários no Dock. |
| Recuperação de ADB | Helper Android opcional para tentar reativar a depuração sem fio depois de alterações da rede, respeitando pausa e autorizações do sistema. |
| Telemetria | Recursos locais do macOS e sondas SSH para Linux, Windows, armazenamento e nós Proxmox; estados de serviços e feeds opcionais de alertas. |
| Widgets de bateria | Widget separado no macOS para quatro dispositivos móveis; widget Android com seis perfis da implementação atual, em uma linha ou duas. Publicadores independentes para macOS, Android e Windows. |
| Interface | Painéis compactos, blocos separados de mídia e ações, vidro escuro opcional e proteção contra recolhimento pelo gesto vertical nas áreas com rolagem. |

Os módulos são opcionais. Não é necessário configurar computadores remotos ou aparelhos para usar os recursos locais. A versão atual conserva uma topologia de exemplo em algumas tabelas do código; ela deve ser adaptada antes de instalar as integrações em outro ambiente.

## Requisitos

- macOS e Xcode com SDK compatível com o projeto. O target principal declara macOS 14; algumas funções de captura e áudio dependem de APIs e permissões de versões mais recentes.
- Node.js e npm para os helpers de atividade e KDE Connect; Python 3 para os brokers, filas e baterias.
- As ferramentas de linha de comando do Xcode para compilar e assinar localmente.
- Integrações opcionais: KDE Connect, scrcpy, Android Platform Tools, Deskflow, FFmpeg e um ambiente Python com `faster-whisper` para transcrição.
- Para os apps Android: JDK 21, plataforma Android API 36 e Build Tools correspondentes.
- Para o widget macOS: Xcode e, se for regenerar o projeto, XcodeGen.

Alguns scripts esperam binários do Homebrew em `/opt/homebrew/bin` e apps em `/Applications`. Revise esses caminhos em instalações Intel ou com outra organização. Os caminhos remotos, perfis de dispositivos e executáveis dos workers também precisam corresponder à sua instalação.

## Compilar, testar e instalar

A partir da raiz do checkout:

```bash
(cd Integrations && npm ci --omit=optional --ignore-scripts)
Scripts/run-pedro-tests.sh
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch \
  -configuration Release -derivedDataPath /tmp/insight-notch-build \
  CODE_SIGNING_ALLOWED=NO build
```

Esse comando apenas compila. Para compilar e substituir a instalação local, depois de revisar as configurações:

```bash
script/build_and_run.sh --verify
```

O instalador faz backup do app, das preferências e das integrações existentes; copia os helpers; assina localmente; repara registros antigos de lançamento; e abre `/Applications/Insight Notch.app`. A opção `--install-built` usa a build do diretório interno do instalador, não uma build de qualquer outro diretório.

O identificador de preferências permanece `theboringteam.boringnotch`, para manter compatibilidade. Ative a inicialização ao entrar no sistema nas configurações do app. Não aponte o item de login para uma cópia de backup.

A assinatura local não equivale a uma distribuição notarizada. Os pacotes oficiais do projeto original não incluem as alterações desta edição e podem substituí-las se forem instalados por cima.

## Permissões do macOS

Conceda cada permissão apenas ao componente que a usa, em **Ajustes do Sistema → Privacidade e Segurança**:

| Permissão | Uso |
| --- | --- |
| Acessibilidade | Atalhos e interação assistida com janelas; o Deskflow precisa da própria autorização. |
| Monitoramento de Entrada | Captura de entrada pelo Deskflow, conforme solicitado pelo sistema. |
| Gravação de Tela e Áudio do Sistema | Captura de área, prévias de janelas e funções do mixer que usam captura de áudio. |
| Notificações | Exibição nativa das notificações encaminhadas. |
| Calendários e Lembretes | Recursos correspondentes do painel inicial. |

Depois de recompilar um app com assinatura local, o macOS pode exigir renovar a autorização daquela versão. Ver o controle habilitado não garante que a captura já funcione: reabra o app e teste a função. No Linux, confirme também os diálogos da sessão gráfica necessários ao compartilhamento de entrada.

## Configuração local e SSH

Use aliases próprios e contas autorizadas no seu `~/.ssh/config`. Nunca copie uma chave privada para o repositório. Exemplo de alias genérico:

```sshconfig
Host workstation
    HostName workstation.example.invalid
    User operator
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Substitua o domínio de exemplo e confirme a conexão no terminal antes de habilitar uma integração:

```bash
ssh -o BatchMode=yes workstation hostname
```

As sondas de telemetria usam destinos e identidades explícitos; não presuma que todos os módulos herdem automaticamente esse alias. Os mapas de workers, os nomes de telas e os perfis móveis também são configurações independentes.

| Configuração | Onde revisar |
| --- | --- |
| Destinos de telemetria, preferência de host e sonda Windows | [Provider de operações](boringNotch/Providers/PedroOpsProvider.swift). |
| Nós de virtualização e identidade SSH por nó | [Modelos de virtualização](boringNotch/models/PedroProxmoxModels.swift). |
| Serviços, feeds e conjuntos de armazenamento | [Provider de serviços](boringNotch/Providers/PedroStackProvider.swift). |
| Destinos de processamento, intérpretes e caminhos remotos | [Broker de arquivos](Integrations/desk-hub.py). |
| Raízes pesquisáveis, ferramentas e execução de trabalhos | [Worker](Integrations/desk-worker.py). |
| Telas, nomes internos e disposição de teclado/mouse | [Controle de mesa](Integrations/deskflow-control.py). |
| Pareamentos, identificação por modelo e perfis do espelhamento | [Helper de dispositivos](Integrations/scrcpy-phone.py) e [manager móvel](boringNotch/Providers/PedroPhoneManager.swift). |

Na árvore configurável, os resolvedores de preferências aceitam ajustes locais com `defaults`. Use a chave que realmente estiver definida no módulo, não o marcador deste exemplo:

```bash
# Com o app parado; substitua PREFERENCE_KEY e o valor antes de executar.
defaults write theboringteam.boringnotch PREFERENCE_KEY -string 'operator@workstation.example.invalid'
```

Nem todos os módulos possuem tela de configuração ou arquivo JSON universal. Onde houver tabela fixa, adapte o código e recompile. Os exemplos não fazem provisionamento remoto, não concedem acesso SSH e não alteram firewalls.

## KDE Connect: aparelhos, mensagens e mídia

1. Instale e abra o KDE Connect no macOS e em cada dispositivo móvel; confirme o pareamento nas duas pontas.
2. No dispositivo, habilite os plugins necessários: bateria, notificações, compartilhamento e controle de mídia. Para mensagens, conceda acesso às notificações e permita os aplicativos desejados.
3. Configure os perfis e rótulos locais no manager móvel. Os IDs devem ser os do seu pareamento, sem reutilizar exemplos.
4. Para usar um relay Linux, instale nesse usuário os helpers Node e suas dependências em `~/.local/share/pedro-notch/`, e confirme o KDE Connect na sessão D-Bus desse usuário.
5. Se sua árvore contiver `Config/integrations.example.json` e `Integrations/local-config.cjs`, copie o exemplo para `~/.config/pedro-notch/integrations.json`. Defina `relayHost` com um alias SSH autorizado e `deviceNames` com os IDs e rótulos escolhidos. Um relay vazio deixa somente os pareamentos diretos.
6. Na árvore sem esse resolvedor, ajuste o destino diretamente nos helpers de telefone e transferência antes da instalação.

O encaminhamento nativo tenta substituir apenas o popup duplicado de notificação do KDE Connect e restaurar a configuração anterior ao parar. A resposta só aparece quando a notificação fornece uma ação compatível. Nem toda notificação ou player oferece resposta, seek ou controle remoto.

A mídia do computador usa a integração nativa do macOS. A mídia do dispositivo móvel depende do player que o KDE Connect expõe. Não é necessário adicionar um cliente específico para cada serviço de streaming.

## Apps Android e depuração sem fio

1. Habilite as opções de desenvolvedor e a depuração sem fio no aparelho.
2. Faça o pareamento com o Android Platform Tools usando o código exibido pelo próprio Android. A porta de pareamento pode ser diferente da porta de conexão.
3. Confirme `adb devices` e adapte os perfis do helper de dispositivos, incluindo identificação de hardware quando usada.
4. Instale scrcpy no caminho esperado pelo helper, ou ajuste esse caminho.
5. Na interface, selecione o dispositivo e abra o espelhamento ou um aplicativo em janela.

As janelas de aplicativos usam um display virtual quando suportado. O helper [de ícones](Integrations/AndroidAppIcons/build.sh) obtém os ícones do aparelho; seu APK deve ser compilado e instalado para esse fluxo. Cada janela recebe uma identidade própria de app, e seu encerramento normal não deve relançá-la automaticamente.

Para a recuperação opcional de depuração:

```bash
bash Integrations/AndroidAdbKeeper/build.sh
adb -s SERIAL install -r /caminho/InsightAdbKeeper.apk
adb -s SERIAL shell pm grant --user 0 marketing.insight360.adbkeeper android.permission.WRITE_SECURE_SETTINGS
adb -s SERIAL shell pm grant --user 0 marketing.insight360.adbkeeper android.permission.POST_NOTIFICATIONS
adb -s SERIAL shell dumpsys deviceidle whitelist +marketing.insight360.adbkeeper
adb -s SERIAL shell am start-foreground-service \
  -n marketing.insight360.adbkeeper/.KeeperService \
  -a marketing.insight360.adbkeeper.START
```

`SERIAL` e o caminho do APK são marcadores; substitua-os pelos seus valores locais. `WRITE_SECURE_SETTINGS` é uma permissão ampla: o helper a usa para solicitar a ativação da depuração sem fio. É possível pausá-lo pelo app ou notificação e revogar essa permissão por ADB.

A recuperação exige Wi-Fi disponível e as opções de desenvolvedor/depuração necessárias habilitadas. O Android continua responsável por confiar na rede e autorizar o computador. O helper não aprova redes novas, não troca a ROM, não faz root e não força a porta TCP legada. Bloqueio, suspensão e restrições do fabricante ainda podem impedir a imagem ou atrasar a conexão.

## Arquivos, busca e processamento

1. Instale Python 3 em cada destino e copie `Integrations/desk-worker.py` para o caminho configurado no broker.
2. Instale FFmpeg para áudio/vídeo. Para transcrição, configure `faster-whisper` e disponibilize previamente um modelo local compatível.
3. Adapte os aliases, os intérpretes e os caminhos permitidos no broker. O transporte de arquivos valida o formato do caminho remoto; mudar somente o alias não basta.
4. Revise as raízes de busca do worker. A busca é por nome e metadados em raízes limitadas, não um indexador semântico de todo o disco.
5. Teste as capacidades do destino pela interface antes de enviar um trabalho. No Windows, a execução agendada precisa sobreviver ao encerramento da sessão SSH; valide o intérprete e o Agendador no seu ambiente.

A área de arquivos reúne **Cópias**, **Processar** e **Buscar arquivos**. O processamento aceita seleção automática ou explícita de destino. A fila é persistente e ordenada por destino; progresso, cancelamento e falhas permanecem visíveis. Os resultados são recebidos em `~/Downloads/Insight Notch` após verificar o SHA-256. As credenciais SSH não são sincronizadas com os arquivos.

A transcrição atual é local, em CPU e com modelo previamente disponível. Não há promessa de aceleração de GPU, carregamento de modelo arbitrário ou processamento quando o computador de destino estiver suspenso.

## Mesa contínua com Deskflow

1. Instale Deskflow no computador macOS e nos destinos. Revise os caminhos de `deskflow-core` nos helpers.
2. Configure nomes internos de tela consistentes no controlador e nos workers, e adapte os aliases SSH usados pelos túneis.
3. Conceda as permissões de entrada ao Deskflow em cada sistema.
4. Na área **Mesa contínua**, escolha a disposição e inicie a sessão. Confirme que os clientes aparecem conectados antes do teste físico.
5. Leve o cursor até uma borda configurada. `Control+Option+Home` solicita o retorno ao computador macOS.

O servidor escuta em loopback; os clientes chegam por túneis SSH. O transporte interno do Deskflow nesta implementação depende desse isolamento: não exponha diretamente sua porta em uma interface pública. Teclado, mouse e clipboard dependem de uma sessão gráfica disponível e das permissões do sistema.

## Widgets de bateria pela internet

### Funcionamento

A central Python/SQLite recebe somente porcentagem e estado de carregamento. Cada cliente usa um token próprio, publica a própria bateria e lê o último snapshot do conjunto. O servidor guarda hashes SHA-256 dos tokens e restringe a escrita à identidade autenticada.

O widget do macOS é separado do widget nativo do sistema, que continua disponível para acessórios. O widget Android inclui os perfis móveis e dos computadores, com ícones distintos e disposição em uma linha ou duas. A quantidade e os perfis refletem as tabelas atuais do código, não uma descoberta automática de qualquer equipamento.

O publicador do macOS consulta a cada 30 segundos enquanto o sistema permite executar. O publicador Windows envia a cada 30 segundos. No Android, eventos de bateria/rede e um serviço visível sustentam a sincronização, com ciclo de 60 segundos e um job periódico de fallback. O WidgetKit e o Android podem adiar atualizações. Leituras com mais de 180 segundos são marcadas como antigas/offline.

### Configurar a central

1. Personalize os IDs e rótulos em `Integrations/battery-hub/server.py`, os perfis dos clientes, o desenho dos ícones e o provisionador. Os conjuntos e identidades precisam corresponder.
2. Gere tokens aleatórios separados para cada identidade fora do checkout. Para `--keys`, grave um objeto JSON que associe cada ID ao hash hexadecimal SHA-256 de seu token. Os clientes recebem apenas o próprio token bruto.
3. Execute a API inicialmente em loopback, com arquivos privados e SQLite persistente:

```bash
python3 Integrations/battery-hub/server.py \
  --bind 127.0.0.1 --port 17874 \
  --state "$HOME/.local/share/insight-batteries/state.sqlite3" \
  --keys "$HOME/.config/insight-batteries/keys.private.json"
```

4. Publique `/v1/batteries` em um endpoint HTTPS sob seu controle, por exemplo `https://batteries.example.com/v1/batteries`. O arquivo de serviço fornecido é uma referência e precisa de revisão de caminhos, bind e origem permitida. Um conector em outro computador precisa alcançar o bind escolhido.
5. Use uma origem privada e restrição de origem quando houver um túnel ou proxy remoto. Não é necessário expor a API sem autenticação no roteador.
6. Substitua consistentemente o endpoint validado no bridge macOS, no cliente Android e no publicador Windows antes de compilar/provisionar. Não use um endpoint de exemplo como serviço real.

### Cliente e widget macOS

Crie `~/.local/share/pedro-notch/battery-hub-client.json`, com permissão de arquivo `600`, contendo `endpoint` e `token` dessa identidade. Use valores gerados localmente; nenhum token é fornecido neste repositório. A presença desse arquivo ativa o modo de internet e permite que os demais clientes funcionem sem manter este computador acordado.

Compile o projeto do widget:

```bash
xcodegen generate --spec Widgets/macOS/project.yml
xcodebuild -project Widgets/macOS/InsightBatteries.xcodeproj \
  -scheme InsightBatteries -configuration Release \
  -derivedDataPath /tmp/insight-widget-build \
  CODE_SIGNING_ALLOWED=NO build
```

O instalador do widget espera um diretório de produtos Release. Na árvore configurável, use:

```bash
WIDGET_BUILD_PRODUCTS=/tmp/insight-widget-build/Build/Products/Release \
  bash Widgets/macOS/install.sh
```

Se sua árvore não tiver esse override, ajuste a variável de build do instalador antes de executar. Depois de criar a configuração de internet, instale o publicador local:

```bash
bash Widgets/install-services.sh
```

Adicione o widget pela galeria do macOS. O instalador de serviços cria a inicialização por usuário e o ciclo de coleta; com a central configurada, desativa o antigo helper de manter o computador acordado. Ele não elimina as regras de suspensão do sistema nem a necessidade de internet do cliente.

### Cliente e widget Android

Na árvore configurável, defina `ANDROID_SDK_ROOT` e `JAVA_HOME`; na árvore com caminhos locais fixos, ajuste-os no script de build. Use a mesma chave de assinatura para atualizar uma instalação já existente, mantendo essa chave fora do Git.

```bash
bash Widgets/Android/build.sh
adb -s SERIAL install -r /caminho/InsightBatteries.apk
```

Adapte as identidades de hardware do provisionador `Widgets/deploy-android-cloud.py` e use um arquivo local privado com `endpoint` e `tokens` por ID para instalar/configurar os dispositivos já autorizados. O provisionamento usa um receiver protegido, acessível ao shell ADB; o APK não carrega as credenciais reais. Depois disso, o envio pela internet dispensa ADB.

Permita as notificações e a execução em segundo plano para o app. O provisionador também permite a exceção de otimização de bateria apenas para esse pacote. Abra o app, confirme a conexão com a central, escolha **Uma linha** ou **Duas linhas** e adicione o widget no launcher.

### Publicador Windows

Copie `windows-publisher.py` e `install-windows-publisher.ps1` para `%USERPROFILE%\.local\share\insight-batteries`. Crie ali `client.json` com o endpoint e somente o token dessa identidade. Revise os caminhos do Python no instalador.

Execute o instalador no Windows com a conta que executará a tarefa. Ele restringe o diretório ao usuário e ao sistema, testa uma publicação e registra `InsightBatteriesPublisher` para iniciar ao ligar e ao entrar na conta, com recuperação após falha. A leitura usa o estado nativo de carregamento, não apenas a presença de alimentação externa.

O publicador não muda o plano de energia, o comportamento da tampa, as ventoinhas ou a suspensão. Uma tampa fechada só permite envio contínuo se o Windows continuar acordado e conectado. Em suspensão, desligado ou sem internet, os outros clientes conservam a última leitura.

## Uso de IA, eventos e fontes opcionais

- **Codex:** usa o `app-server` autenticado localmente quando disponível; não requer publicar sua credencial no projeto.
- **Claude:** usa a sessão e as fontes locais configuradas para o usuário. O leitor da API procura o cookie local em `~/.pedroops/claude_cookie.txt`; mantenha o arquivo privado, sem incluí-lo no checkout. O histórico de uso do app de desktop também pode complementar as leituras quando disponível.
- **Gemini:** entre na sua conta no perfil desejado do Microsoft Edge. Configure `~/.pedroops/gemini-usage.json`, com permissão `600`, contendo `edgeProfile` (`Default` ou `Profile N`) e `expectedAccountHash` (SHA-256 do e-mail normalizado com espaços externos removidos e letras minúsculas). O helper lê somente os cookies necessários em modo de leitura, usa o Chaves do macOS para a criptografia existente e confirma a conta antes de consultar a cota. Não depende de uma janela aberta ou de Acessibilidade. Cookies ficam em memória e só são enviados ao provedor; não são gravados no JSON. Cotas de Apps e de CLI são fontes diferentes. A consulta usa um contrato web não documentado que pode mudar.
- **OpenCode:** o histórico local pode complementar o uso quando a base correspondente existir. Ausência de dados não representa uma cota confirmada em zero.
- **Preços e histórico:** estimativas dependem da tabela e das leituras disponíveis; não são uma fatura do provedor.
- **Atividade:** o helper `Integrations/notch-notify.cjs` e a skill local em `Integrations/notch-activity/SKILL.md` recebem eventos explícitos. Ocultar Dot nas configurações preserva os demais eventos de transferência.
- **Alertas e serviços:** configure um feed próprio nas preferências lidas pelos providers. Os feeds são opcionais; dados antigos e indisponibilidade têm estado próprio.

Para Links, configure `pedro_capture_vault_path` com seu diretório local do Obsidian. A captura exige URL válida e gera Markdown para análise posterior; não faz leitura automática da página nem indexação do conteúdo remoto.

## Diagnóstico

| Sintoma | O que conferir |
| --- | --- |
| KDE Connect indisponível ou `ServiceUnknown` | App aberto, sessão D-Bus do usuário, socket local e relay autorizado. Os fluxos locais e remotos têm reconexão independente. |
| Notificação sem campo de resposta | Plugin ativo, permissão para o app de origem e existência de ação de resposta na notificação. |
| Player remoto vazio | Player em execução e exposto pelo plugin de mídia; conexão ativa do dispositivo. |
| Janela Android sem imagem | Aparelho acordado/desbloqueado quando necessário, transporte ADB válido e suporte ao display virtual. |
| Depuração cai ao trocar de rede | Estado do helper, pausa, permissões, descoberta mDNS e confiança da rede solicitada pelo Android. |
| Destino de processamento offline | SSH sem prompts, Python e caminho do worker, ferramentas instaladas e sessão/tarefa Windows persistente. |
| Mesa inicia mas não controla outro computador | Clientes realmente conectados, permissões do Deskflow e disposição das telas. Um processo aberto sozinho não prova a conexão. |
| Bateria parada | Horário da última leitura, internet do próprio publicador e execução do serviço/tarefa; suspensão não produz uma leitura nova. |
| Captura ou mixer indisponível | Permissão da versão atual do app e requisitos da API usada; reabra e teste a função. |
| App abre duplicado | Item de login, cópias antigas registradas e backups com o mesmo bundle ID. |

Logs e estado dos helpers ficam, em geral, em `~/.local/share/pedro-notch`; trabalhos e estado dos workers ficam em `~/.local/share/insight-notch`. Antes de compartilhar logs, remova conteúdo de notificações, caminhos pessoais, identificadores e credenciais.

## Segurança, limites e manutenção

- Guarde tokens, cookies, chaves SSH, keystores e preferências reais fora do Git. Os arquivos de configuração dos exemplos são locais, não um mecanismo de sincronização de credenciais.
- O pareamento de dispositivos e as permissões de entrada/captura continuam sendo decisões do usuário e do sistema operacional.
- A central de baterias aceita apenas os campos previstos, autentica cada identidade, limita payload e requisições e não recebe mensagens, clipboard ou arquivos.
- Widgets não garantem atualização instantânea; computadores suspensos não continuam executando seus publicadores.
- Cancelamento e retomada das filas dependem do estado persistido, do acesso ao destino e da disponibilidade das ferramentas.
- `Scripts/run-pedro-tests.sh` reúne as verificações de modelos, parsers, fontes de uso, filas, transferências, notificações e baterias. Há também testes Java da política do helper de depuração.
- Em alterações de código, compile a aplicação e os componentes afetados. Uma mudança apenas neste README não exige reinstalar nem reautorizar o app.

## Origem e licença

Derivado do Boring Notch 2.7.3, sob [GPLv3](LICENSE). O [README original](UPSTREAM_README.md), os [avisos de terceiros](THIRD_PARTY_LICENSES) e os créditos presentes no código preservam a atribuição aos projetos de origem. KDE Connect, scrcpy, Deskflow, FFmpeg e os demais componentes externos mantêm suas próprias licenças.
