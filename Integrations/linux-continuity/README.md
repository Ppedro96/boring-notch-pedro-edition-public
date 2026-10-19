# Adaptador nativo Linux: patch incremental

Este pacote preserva o trabalho de continuidade nativa do Insight Notch para Linux, preparado em outubro de 2026. A implementação Qt/QML e seus testes foram produzidos na etapa Linux do projeto e revisados separadamente; os helpers comuns foram exportados da implementação compartilhada revisada. A integração mantém os créditos e a licença GPLv3 do projeto; o texto da licença acompanha o repositório.

O patch contém somente as alterações atribuídas à continuidade e seus testes. Não é uma distribuição Linux independente. A base preparada já tinha componentes nativos de produtividade, alertas, clipboard, Mesa, agentes e dispositivos móveis, além de alterações anteriores que não pertencem a este pacote. Essas alterações anteriores não foram copiadas.

O manifesto identifica a revisão de origem, o hash do patch, os hashes de todos os arquivos-fonte necessários da base e os hashes anteriores e posteriores dos arquivos alterados. A revisão Git isolada não basta: uma cópia limpa dessa revisão não contém todas as dependências da base preparada.

Para reutilizar, primeiro obtenha legitimamente a base preparada, confira todos os hashes de pré-requisito e a ausência dos arquivos marcados como novos, depois confira se o patch se aplica sem conflitos ou tolerância de contexto. Após aplicar, compare cada arquivo alterado com o hash posterior do manifesto. Não substitua divergências por arquivos de trabalho de outra instalação. Sem a base correspondente, o pacote serve como registro revisável e referência para uma adaptação manual.

Compile e execute os testes nativos e de interface na instalação de desenvolvimento apropriada. A validação original usou testes isolados e compilação; isso não prova instalação, clipboard físico, reprodução remota ou qualidade de entrada em outro computador. O pacote não inclui binários, configuração privada, certificados, tokens, capturas, perfis nem estado de execução. Sua aplicação não autoriza reiniciar sessões ou mudar permissões.
