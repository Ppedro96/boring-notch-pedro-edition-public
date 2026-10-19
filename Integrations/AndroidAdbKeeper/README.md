# Recuperação de depuração sem fio

Helper Android opcional que tenta recuperar a depuração sem fio após alterações de conectividade. Mantém a ROM e os pareamentos existentes. Esta documentação explica o mecanismo e a configuração sem comandos, caminhos, identificadores de instalação ou dados de equipamentos.

## Como funciona

Um serviço visível observa mudanças de rede e o estado da depuração sem fio. Após uma mudança, aguarda a estabilização antes de tentar reativar a configuração.

A recuperação só é solicitada quando existe Wi-Fi disponível, as opções de desenvolvedor e de depuração necessárias continuam ativas e o usuário não pausou o helper. O Android mantém a responsabilidade por confiar na rede e autorizar o computador.

As tentativas são limitadas por evento e possuem intervalo mínimo. Um ciclo periódico complementa os eventos de rede, sem manter um wakelock contínuo. O helper tem retomada configurada após inicialização ou atualização do app, sujeita às restrições do sistema.

## Preparação e instalação

1. Prepare o SDK Android e o JDK compatíveis com o projeto.
2. Compile o aplicativo e mantenha uma assinatura local consistente para futuras atualizações.
3. Instale-o por uma conexão de depuração que já tenha sido autorizada pelo usuário.
4. Conceda a permissão necessária para alterar configurações seguras do Android e a permissão de notificação.
5. Permita a execução em segundo plano e, se necessário, uma exceção de otimização de bateria restrita ao helper.
6. Ative o acompanhamento e confirme sua notificação persistente.

A autorização para alterar configurações seguras é ampla. Nesta implementação, seu uso é limitado à solicitação de ativação da depuração sem fio. O controle externo do serviço é protegido pelas permissões do sistema, evitando que aplicativos comuns o acionem.

## Pausar ou remover

A pausa está disponível no app e na notificação. Ela interrompe a recuperação automática sem desfazer o pareamento nem exigir a queda da conexão atual.

Para retirar a autorização, pause o acompanhamento e revogue as permissões concedidas e a exceção de otimização de bateria. A desinstalação também remove as autorizações do aplicativo.

## Limites

O helper não liga o Wi-Fi por conta própria, não aprova redes novas ou computadores, não usa root e não força o modo TCP legado. Desligar as opções de desenvolvedor ou as autorizações necessárias impede a recuperação.

Uma rede nova pode exigir uma confirmação nativa. Bloqueio, repouso, restrições do fabricante e falta de conectividade ainda podem impedir a retomada. O mecanismo é uma tentativa controlada de recuperação, não uma garantia de conexão permanente.

## Validação

As verificações da política cobrem as condições necessárias à recuperação, pausa, ausência de rede ou permissão, configuração já ativa e limite de tentativas.

Em uma instalação própria, confirme a retomada do serviço após atualização e teste a perda e o retorno de conectividade em uma janela apropriada. Não presuma que isso comprove também o comportamento após reinício ou troca para outra rede: esses cenários precisam de validação separada.
