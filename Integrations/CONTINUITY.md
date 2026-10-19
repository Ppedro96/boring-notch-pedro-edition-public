# Continuidade nativa

Este guia descreve a integração opcional entre as interfaces nativas Mac e Linux. Os oito recursos ocupam as áreas existentes do painel. O Windows pode receber entrada e executar processamento por seus componentes próprios; não há aqui uma aplicação Windows que implemente os oito recursos.

O [pacote incremental do adaptador Linux](linux-continuity/README.md) preserva somente suas alterações e testes revisados. Ele exige uma base preparada cujos hashes correspondam ao manifesto; não contém essa base nem representa uma distribuição independente.

Sem configuração privada habilitada, as funções locais continuam funcionando. Habilitar continuidade não concede permissões de entrada, captura, notificações ou depuração e não substitui o pareamento de dispositivos.

## Preparação por função

| Função | Responsabilidade |
| --- | --- |
| Coordenador Linux | Estado comum, revisões, blobs verificados e fila persistente de processamento. |
| Cliente Mac | Interface SwiftUI, fontes locais e uma ponte persistente para o coordenador. |
| Cliente Linux | Interface Qt/QML, fontes locais e uma ponte persistente para o mesmo coordenador. |
| Executor opcional | Ferramentas de processamento no Mac, Linux ou Windows, com acesso e capacidades previamente autorizados. |

1. Preserve a aplicação, os helpers e a configuração atuais para reversão. Confirme que não há processamento ativo antes de substituir componentes que executam trabalhos.
2. Prepare Python e os helpers compatíveis no coordenador e nos clientes. Prepare as ferramentas de conversão ou transcrição somente nos executores que usarão essas funções. A interface Linux precisa de seu adaptador nativo correspondente; copiar somente os helpers deste projeto Mac não cria essa interface.
   Na sessão Wayland do cliente Linux, prepare também as ferramentas de leitura e escrita de clipboard compatíveis com o compositor. A captura valida os formatos oferecidos antes da leitura, e a aplicação automática de conteúdo remoto precisa do gravador Wayland; um teste isolado de interface não comprova essa dependência na sessão gráfica real.
3. Use o SSH privado já autorizado. Cada cliente recebe uma identidade lógica estável e exclusiva, ligada à função autenticada no coordenador. A configuração confiável determina o destino e o processo remoto; o conteúdo compartilhado trafega como dados, sem virar instrução de shell.
4. Defina armazenamento privado persistente no coordenador e cache privado separado em cada cliente. Preserve esses dados nas atualizações: contêm estado, alterações pendentes, proveniência e os arquivos necessários para receber resultados ou repetir trabalhos.
5. Configure privadamente o acesso ao coordenador, a identidade de cada cliente, as funções dos executores e os locais permitidos para busca e processamento. Não copie configuração, identidades de entrada, tokens de sessão ou credenciais para o repositório.
6. Mantenha a continuidade desativada até que as funções e os acessos sejam conferidos. Habilite explicitamente os clientes participantes e confirme na interface se os dados são atuais, antigos ou indisponíveis.
7. Na integração Linux com um gerenciador de serviços por usuário, mantenha os trabalhos persistentes fora do grupo encerrado junto com a aplicação. Use a política já revisada da instalação; desligar a ponte deve encerrar somente seus próprios processos e conexões.
8. Valide com conteúdo sintético: texto e PNG, fixação e remoção, arquivo da Shelf, nota, alerta, tarefa, mídia, processamento e estado da Mesa. Compare integridade ao receber arquivos. Confirme também as funções locais com a continuidade indisponível.

O transporte é SSH com mensagens estruturadas por entrada e saída padrão. Uma ponte por aplicação acompanha os tópicos, correlaciona respostas e reconecta com espera limitada. Não é necessário publicar uma nova porta na internet. A reconexão da ponte não reinicia a Mesa, o espelhamento Android nem um trabalho persistente já aceito.

## Estado durável e privacidade

Metadados usam revisões e identificadores de alteração para evitar duplicação. Cada item identifica sua origem. O cache mantém a última visão disponível e uma fila de alterações pendentes; uma visão antiga não significa conexão ativa. Uma alteração rejeitada preserva conteúdo local e produz aviso. O cliente conserva conflitos recuperáveis, mas a interface nativa não oferece um gerenciador completo desses conflitos.

Somente novos eventos elegíveis publicam conteúdo. A integração não varre arquivos, histórico antigo ou notas antigas para enviá-los. Receber uma remoção compartilhada retira o item comum; não apaga o arquivo original. A procedência persistente permite reconciliar remoções feitas enquanto uma aplicação estava fechada.

Arquivos são enviados e recebidos em blocos com tamanho e SHA-256 verificados. Um resultado concluído no executor ainda precisa ser recebido: a ação nativa obtém uma cópia no cache local verificado antes de abrir ou revelar o arquivo. Um endereço de arquivo no coordenador não é tratado como arquivo local do cliente.

Alterações elegíveis de metadados podem aguardar reconexão. Envio de arquivos, obtenção de blobs ausentes, submissão de processamento e ações de controle precisam de conexão. Arquivos já verificados no cache e recursos locais permanecem utilizáveis. Um envio local que falhou exige a tentativa explícita oferecida pela interface; não há promessa de varredura histórica posterior.

## Oito recursos

### Mesa contínua

A interface consulta a disposição e o estado do controlador comum. Escolher um layout é uma ação explícita; consultar status não inicia, pausa ou reconfigura a entrada. A linha conecta somente vizinhos pelas bordas internas, mantendo as bordas externas locais. O atalho de retorno respeita a origem física do teclado.

Pronto indica capacidade nativa disponível; conectado indica uma ligação observada; pendente indica um participante excluído ou ainda indisponível. Um processo aberto não comprova controle físico. Se o participante central estiver indisponível, uma solicitação explícita de iniciar ou mudar layout pode unir o par disponível. Quando ele voltar, outra solicitação reconcilia a linha completa. Não há recuperação automática de toda topologia por mera consulta.

Certificados, identidades e autorizações de sessão permanecem privados. Recuperação limitada do receptor Windows reaproveita a sessão autorizada, sem garantir recuperação de permissões revogadas. O candidato opcional de captura Linux é uma avaliação separada; compilação e prontidão não demonstram melhora física nem significam instalação desse candidato.

### Clipboard, histórico e fixação

Os clientes nativos compartilham texto UTF-8 exato, inclusive seus espaços, e os bytes originais de PNG. A identidade por hash é comum entre plataformas. Fixação altera somente o estado do item; remoção é comum. Imagens ainda não armazenadas podem ser recebidas explicitamente pelo histórico.

Conteúdo marcado como privado, oculto, transitório, gerado automaticamente ou associado a gerenciadores de senhas é excluído. Referências locais a arquivos não viram clipboard compartilhado. No Linux, a captura valida os formatos oferecidos antes de ler um tipo suportado; não recupera conteúdo privado por um histórico alternativo.

A ativação automática exige uma captura remota nova, recente e mais nova que a captura local. Histórico inicial, cache, repetição de alterações, eco da própria origem e mudança de fixação não substituem o clipboard. Antes de aplicar uma imagem recebida com atraso, o cliente verifica novamente o estado local; no Wayland, também confere a oferta atual. A seleção manual de um item é uma ação explícita. Isso reduz substituições atrasadas, mas não equivale a uma garantia de privacidade de qualquer aplicativo que omita suas marcações.

### Shelf

Novos arquivos arrastados, textos e links entram na área compartilhada com origem explícita. Arquivos exigem envio verificado; o outro cliente recebe sob demanda e pode abrir ou usar a cópia local. A Shelf local continua disponível. Remover um item comum não remove seu arquivo original. Conteúdo anterior à ativação não é enviado em lote.

### Processamento

A fila comum registra origem, destino, progresso e estado durável. O arquivo selecionado é preparado como blob verificado, sem usar um caminho privado do cliente como endereço remoto. A repetição utiliza a entrada retida e o identificador do trabalho. Cancelamento solicitado permanece distinto de cancelamento confirmado; arquivar retira a tarefa da lista sem prometer apagar seus resultados.

Histórico local anterior aparece separado e permite consultar ou receber resultados, sem transformar caminhos privados antigos em novas submissões comuns. A disponibilidade depende de o executor estar acordado, acessível e equipado para a operação escolhida. Receber o resultado verifica a cópia local antes de apresentá-la ao usuário.

### Mídia

Escolha explicitamente o computador no painel de mídia. A seleção remota não troca o player local nem os controles locais do Mixer. Os comandos capturam o destino escolhido no momento do clique; o receptor executa somente no seu player local, independentemente da seleção visível em sua própria interface.

Comandos têm validade curta, verificação de destino e proteção contra repetição. Não ficam na fila offline. Leituras remotas antigas tornam o computador indisponível; não demonstram reprodução atual. Heartbeats de mídia conservam a disponibilidade, sem substituir a informação local de reprodução.

### Links e capturas

Somente uma nova gravação local bem-sucedida publica metadados. Título e observação originais são preservados; o marcador de sincronização permanece falso. Quando conectado, o Markdown pode acompanhar a nota como blob verificado. Offline, os metadados podem aguardar, enquanto o Markdown opcional permanece local até uma publicação online correspondente.

Abrir o link e baixar seu Markdown são ações distintas. Notas grandes podem ter prévia limitada; o Markdown completo fica no blob opcional. A integração não abre conteúdo remoto sozinha e não o envia automaticamente para indexação ou memória semântica.

### Alertas

O reconhecimento comum identifica o alerta original e o hash do seu estado. Somente o mesmo par é suprimido; um hash alterado reaparece. Reconhecimentos recebidos não são republicados. Alertas locais do computador, verificações SSH e limites de uso continuam locais, sem suprimir avisos diferentes por coincidência de título.

### Tarefas de agentes

Cada resumo tem identidade vinculada ao computador, provedor e tarefa ou sessão. Eventos da mesma tarefa convergem sem misturar origens independentes. A interface mostra origem, título limitado, estado legível, progresso na escala de zero a cem e um resumo curto. Quando a origem não informa progresso, os publicadores de eventos usam padrões inferidos: zero para tarefas não concluídas e cem para concluídas. Esses valores representam o estado da tarefa, não uma medição do trabalho realizado. Leituras antigas são indicadas, sem renovar o horário do evento apenas por consultar a interface.

As tarefas em andamento ou aguardando aparecem antes das finalizadas. Dentro de cada grupo, o horário do evento de origem ordena as mais recentes primeiro, com identidade estável para desempate. Essa ordem é somente visual: preserva o histórico e as ações das sessões locais.

Não são compartilhados prompts, transcrições, diretórios de trabalho, modelos, tokens ou respostas de permissão. Não existem controles remotos para aprovar permissões. As ações e permissões das sessões locais permanecem no computador de origem. Um resultado só aparece quando a origem fornece um blob válido; o adaptador não inventa um arquivo de resultado a partir de um resumo.

## Conferência e recuperação

| Situação | Conferir |
| --- | --- |
| Continuidade desativada | Habilitação explícita e configuração privada compatível; recursos locais devem continuar disponíveis. |
| Dados antigos ou offline | Acesso SSH, coordenador, identidade exclusiva e estado da ponte. Preserve cache e alterações pendentes. |
| Item não publicado | Elegibilidade, marcações de privacidade, confirmação de gravação local e necessidade de envio online. |
| Resultado não disponível | Estado final do trabalho, presença do blob, conexão e verificação da cópia no cliente. |
| Mídia não responde | Computador selecionado, player local no destino, leitura recente e sessão receptora ativa. |
| Alerta voltou | Compare o estado atual: uma mudança de hash deve produzir um novo aviso. |
| Mesa pronta sem controle físico | Confirme ligações observadas, layout e autorizações nativas; prontidão isolada não basta. |

Antes de restaurar uma versão anterior, preserve os dados comuns e alterações novas. Não substitua o estado durável por uma cópia antiga sem reconciliação. Diagnósticos e logs podem conter dados pessoais; revise-os antes de compartilhar. Build, testes isolados, instalação, conexão e uso físico são evidências diferentes e devem ser registrados separadamente.
