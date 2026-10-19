# Depuração Insight — Android ADB Keeper

App local separado, instalado somente no Tab S8+ SM-X806B, Android16. Mantém a ROM e os pares ADB existentes. Não usa root, acessibilidade, Internet, localização ou porta5555.

## Comportamento

Serviço foreground `specialUse` observa redes com transporte Wi-Fi e `Settings.Global.adb_wifi_enabled`. Após mudança aguarda2,5s; se depuração sem fio estiver desligada com Wi-Fi disponível, opções de desenvolvedor e depuração USB ainda ligadas, solicita `adb_wifi_enabled=1`. O próprio Android valida a rede e exibe seu diálogo quando necessário. Nenhuma rede ou computador é aprovado automaticamente.

No máximo três tentativas por evento/rede, intervalo mínimo8s; após sucesso estável o contador reinicia. Heartbeat60s funciona como fallback, sem wakelock. O botão Pausar do app/notificação desativa a recuperação e preserva a conexão ADB atual. Desligar as opções de desenvolvedor ou a depuração USB também impede recuperação. START_STICKY e receiver BOOT_COMPLETED/MY_PACKAGE_REPLACED retomam apenas se a opção estiver ativa. Reboot real não testado; retomada após atualização do APK confirmada.

## Permissões e instalação

`WRITE_SECURE_SETTINGS` é ampla e concedida uma vez por ADB; o código escreve somente `adb_wifi_enabled`. `ACCESS_NETWORK_STATE`, `RECEIVE_BOOT_COMPLETED`, permissões FGS/specialUse e POST_NOTIFICATIONS sustentam a monitorização visível. Serviço exportado exige `android.permission.DUMP`; apps comuns não podem acionar seu controle. Activity do usuário não recebe comandos automáticos externos.

Package: `marketing.insight360.adbkeeper`. Build: `bash Integrations/AndroidAdbKeeper/build.sh`, SDK oficial36/build-tools36 eJDK21 do workspace t9. Usa assinatura local de desenvolvimento existente do projeto; não versionar a chave.

Depois de `adb -s SERIAL install -r InsightAdbKeeper.apk`:

```
adb -s SERIAL shell pm grant --user 0 marketing.insight360.adbkeeper android.permission.WRITE_SECURE_SETTINGS
adb -s SERIAL shell pm grant --user 0 marketing.insight360.adbkeeper android.permission.POST_NOTIFICATIONS
adb -s SERIAL shell dumpsys deviceidle whitelist +marketing.insight360.adbkeeper
adb -s SERIAL shell am start-foreground-service -n marketing.insight360.adbkeeper/.KeeperService -a marketing.insight360.adbkeeper.START
```

Whitelist de bateria é restrita a esse app; não altera economia global do tablet. Pausar pelo app/notificação, ou comando shell protegido `am start-foreground-service -n marketing.insight360.adbkeeper/.KeeperService -a marketing.insight360.adbkeeper.PAUSE`.

Para retirar a autorização: pausar, `pm revoke --user 0 marketing.insight360.adbkeeper android.permission.WRITE_SECURE_SETTINGS`, `dumpsys deviceidle whitelist -marketing.insight360.adbkeeper`; desinstalar também remove as permissões. Não é necessário desligar ADB nem desfazer pareamento.

## Validação em 18/10/2026

- Oito checks Java da política: recuperar com Wi-Fi/ativação/permissão; respeitar pausa, ausência de permissão/rede, master/USB desligados, já ativo e limite de tentativas.
- Desativação real `adb_wifi_enabled=0`: Mac perdeu conexão; app reativou localmente e ADB reconectou em6,3s.
- Ciclo real Wi-Fi off/on no tablet por script shell temporário (nohup, atraso2s, Wi-Fi off4s, on): houve perda de ADB e retorno automático em16,4s. Logs do app confirmaram pedido local de recuperação. Router e outras conexões não alterados.
- APK1.0.1/build2 reinstalado; serviço retomado por MY_PACKAGE_REPLACED e foreground confirmado; WRITE_SECURE_SETTINGS/POST_NOTIFICATIONS e whitelist mantidos; ADB ligado e bridge de bateria executado.
- Reboot real e troca para outro SSID não foram testados. Rede nova pode exigir uma autorização nativa. Sem Wi-Fi disponível o serviço aguarda; não liga Wi-Fi por conta própria.

Referências: Android FGS specialUse https://developer.android.com/develop/background-work/services/fgs/service-types#special-use ; mecanismo Settings.Global/WRITE_SECURE_SETTINGS documentado pelo autor https://github.com/retransmit/DevSwitch . Implementação própria, sem copiar código externo.

## S23 Ultra / X99 — 18/10/2026

Mesmo APK1.0.1/build2 instalado também no SM-S918B DEMO_S23, Android16, via ADB existente do X99. WRITE_SECURE_SETTINGS e POST_NOTIFICATIONS concedidas ao user0, whitelist de bateria somente para o app e serviço foreground ativo. Rede Insight_Starlink com sinal -26dBm; AP atual já consta no estado confiável do ADB. Troca automática por redes melhores já estava em0 e permaneceu assim.

X99 já tem `s23-adb-wifi-keepalive.service` ativo, descobrindo porta TLS por mDNS a cada20s; anúncio vivo e endpoint atual verificados. Serviços/scripts do X99 não foram alterados. `s23-camera-v4l2.service` permaneceu active com mesmo PID2700238 e início22:25:59, conexão TCP com tráfego recente. Não foi forçada queda/reinício do S23, para preservar a câmera em uso. Configuração de retorno após boot existe no app, mas reboot real também não foi testado no S23. Bridge de baterias executado após instalação.
