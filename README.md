# Cloudflare Workers Builds — tipscoach-reports

Statisk site för Tipscoach publika rapporter på `tipscoach.mistyspring.xyz`.

## Struktur

```
tipscoach-reports/          ← repo root (PublishEngine skriver hit)
├── index.html              ← genereras av PublishEngine
├── rounds/                 ← genereras av PublishEngine
├── _data/rounds.json       ← genereras av PublishEngine
├── _headers                ← Cloudflare Static Assets HTTP-headers
├── robots.txt              ← crawler-policy
├── package.json            ← npm-metadata
├── wrangler.jsonc          ← Cloudflare Worker-konfiguration
├── src/worker.js           ← minimal Worker (delegat till ASSETS)
├── scripts/
│   ├── build.sh            ← kopierar allowlist → dist/
│   └── test.sh             ← regressionstester
└── dist/                   ← build-output (genereras, INTE commitad)
```

All Worker-, build- och header-konfiguration finns i detta repo — **inte**
duplicerad i `tipscoach-v2`.

## Build

```bash
npm ci
npm run build    # → ./scripts/build.sh
npm test         # → ./scripts/test.sh
```

`build.sh` är fail-closed:
1. **Pass 0** — scannar hela publiceringsytan efter symlänkar (filer OCH
   kataloger). Bygget avbryts om någon symlänk hittas.
2. **Pass 1** — validerar att ALLA filer i publiceringsytan matchar den
   explicita allowlisten. Otillåtna filer, dotfiler och okända kataloger
   ger byggfel.
3. **Pass 2** — kopierar endast godkända filer till `dist/`.
4. **Pass 3** — verifierar att `dist/` inte innehåller förbjudna filer.

## Allowlist

| Plats | Tillåtna filer |
|-------|---------------|
| Rot | `index.html`, `_headers`, `robots.txt`, `sitemap.xml` (opt) |
| `_data/` | `rounds.json` (endast denna fil) |
| `rounds/<id>/` | `index.html`, `analysis.html`, `analysis.json`, `report.html`, `report.json`, `coupon.html`, `coupon.json`, `system.txt`, `round_summary.json`, `agent_summary.html`, `agent_summary.json`, `journal.html`, `journal.json` |
| `rounds/<id>/latest/` | `metadata.json` |
| `rounds/<id>/releases/<rel>/` | Samma som round root + `metadata.json` |
| `rounds/<id>/versions/<ver>/` | Samma som round root + `metadata.json` |

Allt annat — inklusive dotfiler, loggfiler, symlänkar, `.env`, extra JSON —
ger byggfel.

## Regressionstester

```bash
npm test
```

16 tester körs i isolerade temporära kataloger:
1. Normal build
2. Symlänkad round-katalog → fail
3. Symlänkad fil → fail
4. Symlänkad `_data/rounds.json` → fail
5. Otillåten fil (`debug.log`) → fail
6. Extra fil i `_data/` (`secrets.json`) → fail
7. `.env` i roten → fail
8. Ogiltigt argument → fail
9. `dist/` saknar förbjudna filer
10. Verkligt repo-integration (isolerad kopia)
11. Symlänkad rot-fil (`index.html`) → fail
12. Vanlig fil istället för round-katalog → fail
13. Vanlig fil istället för `latest/` → fail
14. Dotfil i `_data/` (`.env`) → fail
15. `dist.bak` i roten → fail
16. `2026/<id>/oavsiktlig.txt` → fail

## Legacy: `2026/`

Den äldre strukturen `2026/<id>/` tillåts explicit — endast reguljära `.html`-filer.
Inga symlänkar, dotfiler, kataloger eller andra filtyper accepteras.

## Deployment

Git-kopplad Cloudflare Workers Builds på `main`:
1. Push till valfri branch → preview-build i PR
2. `npm run build` och `npm test` måste vara gröna före merge
3. Merge till `main` → production-build → `tipscoach.mistyspring.xyz`

**Ingen manuell `wrangler deploy`** i normal produktion.

Custom domain `tipscoach.mistyspring.xyz` är planerad att kopplas till Workern
`tipscoach-reports` — separat från `mistyspringxyz`. Detta är ett kvarstående
driftsteg som kräver verifiering i Cloudflare innan produktionstraffik kan
riktas dit.

## Verifiering

```bash
# Efter deploy
curl -fsS -o /dev/null -w '%{http_code}\n' \
  'https://tipscoach.mistyspring.xyz/?v=test'
curl -fsS 'https://tipscoach.mistyspring.xyz/rounds/<round-id>/system.txt?v=test' | head -1
```
