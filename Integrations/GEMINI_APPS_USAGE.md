# Gemini Apps / Spark usage

`gemini-apps-usage.py` reads the consumer Gemini quota through `jSf9Qc`, the RPC behind `https://gemini.google.com/usage`. It reports both used percentages and precise reset epochs. It never queries Gemini CLI, Code Assist, API-key, Vertex or Antigravity quotas and never generates content.

The helper reads only `__Secure-1PSID` and `__Secure-1PSIDTS` from the configured Edge profile in read-only mode. The macOS Keychain supplies the existing browser encryption key. Credentials remain in memory, are sent only to `gemini.google.com`, and are never logged or copied to a configuration file. Redirects are rejected. Network and Keychain calls have timeouts.

Local configuration is `~/.pedroops/gemini-usage.json`, mode 600, with `edgeProfile` (`Default` or `Profile N`) and `expectedAccountHash` (SHA-256 of the normalized Google account email). The bootstrap identity must match this account before requesting quota. The user must already be signed in to Gemini in that browser profile.

The Notch's existing 60-second usage refresh invokes the helper outside the main thread. It stores only percentages, reset times, observation time and the account hash. Incomplete, rejected or changed responses preserve the last direct reading as stale. Expired reset times do not imply zero consumption. There is no Accessibility or open-window dependency.

This is an undocumented web contract. References inspected on 2026-10-02:

- [TokenYou Gemini adapter](https://github.com/diegoparras/tokenyou/blob/main/src/adapters/gemini.js)
- [CodexBar iOS usage contract](https://github.com/HemSoft/codexbar-ios/blob/5b534db31fc64efc1047a7faa76184d6f67dd1d2/GEMINI-USAGE-CONTRACT.md)

Live comparison against the same account in Gemini Mac 1.124.3.956 matched current 1%, weekly 0%, and both reset timestamps. A subsequent direct reading succeeded with the Usage Limits window closed. Cookies and account identity were not included in fixtures. Parser, rejection, account mismatch and stale-cache regressions are covered by `Tests/GeminiAppsUsageTests.py` and `Tests/PedroOpsNetworkTests.swift`.
