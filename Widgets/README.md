# Baterias Insight

Widgets separados do widget Baterias da Apple. macOS mostra S23 Ultra, S25 Ultra, Z Fold6 e Tab S8+. Android mostra esses quatro, MacBook Pro e Alienware. S23/S25 têm o modelo dentro do desenho; Fold usa uma dobradiça, tablet usa formato paisagem e Alienware tem um notebook angular com o rosto alienígena.

## Layout

- Mac: `Galaxy · Uma linha` (médio, quatro lado a lado) e `Galaxy · Duas linhas` (pequeno, 2×2), na galeria do app Insight Batteries.
- Android: app Baterias Insight → Uma linha (padrão, seis lado a lado) ou Duas linhas (3+3). A escolha atual vale para os widgets desse aparelho. A atualização para a versão 3 foi provisionada em uma linha nos quatro Galaxy. Adicionar widget abre o fluxo nativo do launcher; tamanho ajustável.

O widget nativo do Mac não é alterado. O posicionamento no desktop é feito pela galeria do macOS.

## Sincronização pela internet (versão 3)

Cada Android lê sua própria bateria e envia somente porcentagem e estado de carregamento por HTTPS para `https://batteries.example.com/v1/batteries`. A resposta traz a última leitura dos seis aparelhos. Mac e Alienware publicam suas próprias baterias pelo mesmo endpoint quando estão acordados; os Androids continuam independentes quando eles dormem ou mudam de rede.

A API Python/SQLite roda no X99 em `~/.local/share/insight-batteries`, serviço de usuário `insight-batteries.service` habilitado com linger. O túnel Cloudflare existente publica exclusivamente o hostname de baterias para `192.0.2.10:17874`. A origem aceita apenas o IP do conector CT111 `192.0.2.60`. Sem portas novas no roteador. Cada aparelho tem um token aleatório próprio; o servidor guarda apenas hashes e vincula a escrita à identidade desse token. API limitada a porcentagem e booleano de carregamento, corpo de até 512 bytes, 60 chamadas/minuto por chave e 16 conexões simultâneas. Leituras não autenticadas são rejeitadas. Credenciais não entram no APK nem no repositório.

Android: serviço em primeiro plano do tipo connectedDevice, notificação silenciosa, envio ao mudar porcentagem/carregamento, ao voltar a rede ou tela, e consulta periódica de 60 segundos enquanto o sistema executa o processo. Sem wakelock contínuo. JobScheduler persistente de 15 minutos é o fallback. Início ao ligar o aparelho/depois de atualizar o app; opção de pausar a sincronização dentro do app. Os quatro foram liberados da otimização de bateria para melhorar a entrega em segundo plano. Doze, Samsung e falta de internet ainda podem atrasar execuções; não prometer tempo real absoluto. Últimas leituras com mais de 180 segundos aparecem offline. A própria bateria é sempre lida localmente ao desenhar.

O Mac mantém o LaunchAgent `marketing.insight360.battery-widgets` de 30 segundos. Em modo internet ele não coleta nem envia estados de outros aparelhos por ADB; apenas publica sua bateria, obtém o snapshot e grava atomicamente no container WidgetKit. O orçamento visual do WidgetKit continua sendo controlado pelo macOS. Arquivo de configuração privado: `~/.local/share/pedro-notch/battery-hub-client.json`; diagnóstico `battery-widgets-health.json`. O coletor anterior do KDE/ADB permanece como compatibilidade para instalações sem configuração da central.

O Alienware usa `Integrations/battery-hub/windows-publisher.py`, Python padrão e `GetSystemPowerStatus`, com envio a cada 30 segundos. Carregamento é o sinal nativo da bateria, não apenas estar ligado à tomada. Configuração privada em `%USERPROFILE%\.local\share\insight-batteries\client.json`, pasta com ACL restrita ao usuário e SYSTEM. `install-windows-publisher.ps1` registra `InsightBatteriesPublisher` no Agendador, com início ao ligar e entrar no Windows, S4U e recuperação após falha. Não altera energia, suspensão, AWCC ou ventoinhas. O bridge do Mac aceita o snapshot de seis e filtra Alienware antes do cache: o widget do Mac continua com quatro Samsung.

Instalação Android via `Widgets/deploy-android-cloud.py --config <arquivo-privado> --apk <APK-assinado>` e `--s23` para o S23 pelo X99. A provisão usa o receiver protegido pela permissão DUMP disponível apenas ao shell ADB; depois disso os aparelhos dispensam a depuração. A configuração é privada do app, com backup Android desabilitado. A instalação preserva os widgets existentes; o provisionamento da versão 3 seleciona uma linha conforme solicitado.

## Build e instalação local

Mac: Xcode + xcodegen, `xcodegen generate --spec Widgets/macOS/project.yml`, build Release do scheme InsightBatteries e `bash Widgets/macOS/install.sh`. O script atual usa o derivedData da sessão t9. Host e extensão são assinados ad-hoc; extensão com sandbox. O bridge escreve no container próprio da extensão, sem App Groups fictícios. Incrementar CURRENT_PROJECT_VERSION e CFBundleVersion da extensão ao mudar descritores, para invalidar o cache do chronod.

Android: `bash Widgets/Android/build.sh`, SDK oficial Android 36/build-tools 36 e JDK21. APK assinado com chave local persistente de desenvolvimento em `~/.local/share/pedro-notch/batteries-signing.jks` (não versionada). Instalação incremental `adb install -r`. O script usa o SDK da sessão t9.

## Verificação

`python3 -m unittest discover -s Tests -p test_battery_widgets.py` verifica exclusão de conteúdo privado, seleção de dispositivos e retenção da última leitura ao desconectar. `PedroBatteryWidgetTests.swift` verifica decode, filtro dos quatro Samsung e limite de 180 segundos. Builds Release, assinatura macOS e assinatura APK verificados. Instalação ADB bem-sucedida nos quatro Galaxy e widget de uma linha observado no launcher do S23 com porcentagens atualizadas.

## Repouso do Mac

A central no X99 elimina a necessidade de deixar o Mac acordado para os outros aparelhos. O instalador `Widgets/install-services.sh` detecta a configuração da central e remove do início automático o helper `marketing.insight360.battery-availability`. A assertion e o override da tampa são liberados; nenhuma configuração global de `pmset` foi alterada. Fontes e backups do modo anterior ficam preservados para compatibilidade.

## Verificação da versão 2

`python3 -m unittest discover -s Tests -p test_battery_hub.py` verifica autorização, vínculo da identidade, rejeição de conteúdo extra/valores inválidos, limite de chamadas e persistência. `test_battery_widgets.py` verifica o formato e que o Mac não renova artificialmente o horário de leitura dos outros aparelhos. O teste vivo pausa o coletor do Mac e observa os quatro timestamps Android avançarem na base do X99 enquanto o timestamp do Mac permanece parado. A câmera do S23 permanece independente.

## Verificação da versão 3

`test_windows_battery.py` verifica a leitura do sinal de carregamento e a rejeição de bateria ausente/desconhecida. Os testes da API incluem a identidade própria do Alienware; os do bridge confirmam que o snapshot com seis é aceito, mas o cache do Mac conserva os cinco registros anteriores para o widget de quatro Samsung. A publicação Windows foi conferida em execução contínua pelo Agendador, após encerrar a sessão SSH de instalação; a prévia e o widget na tela inicial do S23 foram conferidos com os seis ícones em uma linha e Alienware com 78%.
