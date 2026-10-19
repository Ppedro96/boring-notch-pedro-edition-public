# Insight Notch

Edição local personalizada para Insight 360, baseada no Boring Notch 2.7.3. Preserva as 15 abas e os recursos existentes, com o painel aberto de 640 × 190.

## Interface

- Nome e emblema da Insight no app, menu, configurações, apresentação e página Sobre.
- Ícones funcionais: Apple para Mac, marca Alienware, servidor para Proxmox, nuvem para VPS, alto-falante para Mixer e cérebro para limites de IA.
- Vidro escuro sutil, com opção em Avançado → Window Appearance → Vidro sutil. A redução de transparência do macOS mantém o fundo opaco.
- Provedor, percentual, janela e renovação em níveis tipográficos distintos. Os três provedores aparecem sem rolagem; o texto completo da renovação continua disponível na ajuda.

## Avisos de uso

80% indica proximidade do limite; 95% indica nível crítico. Apenas cotas atualizadas geram avisos. Dados antigos, comparações relativas e janelas já vencidas não disparam alertas.

O aviso aparece por oito segundos na atividade existente do Notch; clicar abre os limites. A deduplicação por provedor, janela, renovação e nível persiste entre reinícios. Leituras sem data de renovação voltam a permitir avisos depois de uma leitura atualizada abaixo de 80%.

O monitoramento usa as fontes já configuradas, a cada 60 segundos, mesmo com o painel fechado: Claude usage API, Codex app-server e Gemini Apps/Spark. Não troca as cotas do Spark pelas do Gemini CLI.

## Identidade e instalação

Instalado em `/Applications/Insight Notch.app`. Mantém `theboringteam.boringnotch`, o executável `boringNotch` e as preferências existentes. O instalador normaliza CFBundleName antes de assinar, pois o Xcode deriva esse campo do nome interno do produto.

`script/build_and_run.sh` compila, assina localmente e instala com backup do app, integrações e preferências. `--install-built` instala a compilação já pronta. Não recompilar depois de restaurar permissões: a assinatura ad hoc muda com o conteúdo da build.

`script/repair_launch_services.py` encerra cópias antigas em execução e deixa somente o app instalado registrado no LaunchServices. Backups legados de `/Applications/boringNotch.app.*` são preservados em `~/Library/Application Support/PedroEditionBackups/.legacy-apps`; as demais cópias são apenas desregistradas. O relatório JSON fica na pasta de backups. O instalador usa `--stop-all` antes de substituir o app e repara os registros antes de abri-lo.

Em 03/10, o sintoma de abrir Home e depois outra aba foi associado a dois processos simultâneos: um backup antigo e o Insight Notch atual. O item de login também apontava para o backup. A correção encerrou essa instância, removeu registros de cópias antigas e registrou novamente a inicialização automática pelo app atual, sem recompilar nem alterar as autorizações de privacidade.

Ícone macOS: asset existente `insight360_perfil_mac.png`, apenas convertido às resoluções do catálogo. Emblema: PNG oficial, copiado sem alterar o desenho, SHA-256 `e73560c10d3f7386387a274f00932a71eafbd6ad359dcd37bb832e67215a676e`. Marca Alienware: vetor Simple Icons CC0, com origem registrada no código. Créditos e licenças originais preservados.

## Validação em 03/10/2026

- `Scripts/run-pedro-tests.sh`: passou, incluindo fronteiras 79/80/94/95/100, dados antigos, janela vencida, comparação relativa, deduplicação, escalada e persistência.
- Compilação Release: `BUILD SUCCEEDED`; assinatura instalada validada com `codesign --verify --deep --strict`.
- UI real: nome e emblema, 15 abas, três cotas e datas legíveis, VPS com nuvem e mixer com rolagem mantendo o painel aberto.
- Acessibilidade e gravação de tela confirmadas pelo próprio processo após reabrir; áudio confirmado com autorização cujo requisito corresponde à assinatura instalada.
- Código de captura do Dock preservado. As miniaturas não foram verificadas visualmente nesta instalação; as permissões foram restauradas e a versão anterior teve confirmação de imagem real pelo usuário.
- Correção de abertura duplicada: um único processo principal, um único caminho no LaunchServices e item de login ativo em `/Applications/Insight Notch.app`. Sintaxe do instalador/helper validada; teste isolado confirmou preservação da instância atual e de apps alheios, encerramento da cópia antiga e seu helper, e filtragem pelo bundle ID exato.
