# Widgets de bateria

Widgets independentes com aparência próxima dos componentes nativos do sistema, ícones distintos e organização compacta. Esta documentação descreve o funcionamento sem identificar uma instalação, publicar credenciais ou informar comandos e caminhos.

## Apresentação

O widget adicional do macOS mostra quatro perfis móveis. O widget nativo do sistema continua disponível para os acessórios já reconhecidos por ele.

O widget Android mostra seis perfis na implementação atual, incluindo dispositivos móveis e computadores. É possível usar uma linha ou duas. Os perfis e os ícones correspondem a tabelas do código que precisam ser adaptadas para cada instalação.

## Como sincronizamos

Cada cliente lê a própria bateria e envia somente a porcentagem e o estado de carregamento para uma central autenticada. A central usa Python e SQLite para guardar a leitura e seu horário.

Um túnel ou proxy HTTPS publica a central privada. Assim, os clientes móveis continuam sincronizando entre si quando o computador macOS está em repouso ou fora da rede.

Cada cliente recebe uma credencial independente. A central guarda os hashes e permite que a identidade autenticada altere somente a própria leitura. Os clientes consultam o snapshot do conjunto autorizado. Não são transmitidos mensagens, clipboard ou arquivos.

## Etapas de configuração

1. Personalize o conjunto de perfis, a identificação dos clientes e os ícones antes de compilar.
2. Prepare a central com armazenamento persistente e início automático.
3. Gere credenciais individuais fora do repositório e associe seus hashes às identidades no servidor.
4. Prepare a publicação HTTPS e limite o acesso à origem privada.
5. Configure cada cliente com seu destino de conexão e somente sua própria credencial.
6. Compile e instale o widget macOS e o app Android usando as ferramentas de desenvolvimento correspondentes.
7. Faça o provisionamento Android pela depuração já autorizada; as credenciais reais não são embutidas no APK.
8. Prepare o publicador Windows com Python e configure o início automático pelo Agendador.
9. Confirme a conexão e adicione os widgets pelas galerias dos respectivos sistemas.

Os apps Android precisam de permissões de notificação e execução em segundo plano. O provisionamento pode permitir uma exceção de otimização de bateria restrita ao próprio app. Depois da configuração, a sincronização pela internet não depende de ADB.

## Frequência e disponibilidade

Os publicadores de computadores usam ciclos de 30 segundos. No Android, eventos de bateria e rede complementam um serviço visível com ciclo de 60 segundos e um job periódico de fallback. O WidgetKit controla quando a apresentação do macOS pode ser atualizada.

Leituras com mais de 180 segundos aparecem como antigas ou offline. A bateria do próprio Android é lida localmente ao desenhar o widget.

Suspensão, desligamento, falta de internet e restrições de segundo plano interrompem ou atrasam novas leituras. Os demais clientes preservam o último valor conhecido. Tampa fechada não mantém o publicador executando se o sistema suspender.

## Inicialização automática e energia

O publicador macOS é iniciado por usuário. Com a central configurada, o instalador desativa o antigo helper de manter o computador acordado.

O Android tem retomada configurada após inicialização e atualização do app, sujeita às restrições do sistema. O publicador Windows registra início ao ligar e ao entrar na conta, com recuperação após falha.

Os publicadores não modificam o plano de energia, o comportamento da tampa, as ventoinhas ou a suspensão. A central independente reduz a dependência do computador macOS, mas cada cliente ainda precisa executar para publicar sua própria bateria.

## Verificação

As verificações cobrem autenticação, escrita por identidade, rejeição de valores e campos indevidos, persistência, expiração das leituras e filtro dos perfis do widget macOS. A leitura Windows distingue carregamento de simples conexão à alimentação externa.

Para validar uma instalação, confirme que cada cliente publica a própria bateria, que os horários avançam enquanto ele executa e que os widgets preservam a última leitura quando esse cliente fica indisponível.
