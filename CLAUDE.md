# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Node.js service that converts CSV input into the `.XTE` XML file required by the ANS (Brazilian health regulator) "Monitoramento TISS" submission, schema version `01.06.00`. It computes the MD5 hash the spec requires (over ISO-8859-1 bytes), and validates the generated XML against the official XSDs via `libxml2` (through `xmllint-wasm`). Both an HTTP API and a CLI are exposed over the same application layer.

Regulatory version pinned in this repo (see [README.md](README.md)): schema `1.06.00`, file extension `.XTE`, naming pattern `REGANSAAAAMM9999.XTE`. Official source docs/checksums live in `docs/ans/`; the XSDs actually used at runtime are in `schemas/tiss/1.06.00/`.

## Commands

```bash
npm install
cp .env.example .env

npm run dev             # HTTP server with --watch, http://127.0.0.1:3001
npm start                # HTTP server, no watch

npm run gerar -- --csv examples/csv/guia_monitoramento.csv \
  --registro-ans 123456 --competencia 202607 \
  --numero-lote LOTE0001 --sequencial 0001 --output output
npm run gerar -- --sem-movimento --registro-ans 123456 \
  --competencia 202607 --numero-lote LOTE0002 --sequencial 0002

npm run validar -- output/1234562026070001.XTE

npm test                          # node --test (all files under test/)
node --test test/generation.test.js       # single test file
node --test --test-name-pattern="hash"    # filter by test name
npm run test:coverage
npm run lint
npm run format          # prettier --write
npm run format:check
npm run check           # lint + format:check + test — run this before considering work done
```

There is no build step; it's plain ESM Node (`"type": "module"`, Node >= 22.14).

## Architecture

Layered, one-way dependency flow: `interfaces` → `application` → `domain` + `infrastructure`. Neither `application` nor `domain` know about HTTP or CLI.

```
src/
├── domain/monitoramento/   # TISS contract: constants, per-block CSV layouts, metadata
│                           # normalization, CPF/CNPJ (mod-11) validation. No I/O.
├── application/            # use cases: generate-monitoring-file, validate-monitoring-file.
│                           # Orchestrate domain + infrastructure; framework-agnostic.
├── infrastructure/
│   ├── csv/                # parse-monitoring-csv (per-row validation + grouping),
│   │                       # normalizers (encoding/date/decimal/document normalization)
│   └── xml/                # builder + source map, decoder, hash and XSD validators
│                           # (libxml2 via xmllint-wasm)
├── interfaces/
│   ├── cli/                 # generate.js / validate.js, arguments.js for flag parsing
│   └── http/                # Express app, routes, multer memory-storage upload
├── config/                  # env.js — zod-validated process.env (PORT, MAX_FILE_SIZE_BYTES, TISS_SCHEMA_VERSION, ...)
└── shared/                  # AppError hierarchy, pino logger
```

`public/` is a static vanilla HTML/CSS/JS frontend (no framework, no build step) served directly by Express (`express.static`, wired in `interfaces/http/app.js`) — it's a thin form over the same `/api/v1/monitoramento/*` endpoints, not a separate app.

Full data flow (see [docs/ARQUITETURA.md](docs/ARQUITETURA.md)):

```
CSV + metadata → per-row normalize/validate → group by chave_registro
  → TISS block model → XML in exact XSD element order → MD5 hash of leaf values
  → epilogue → libxml2 XSD validation → REGANSAAAAMM9999.XTE (ISO-8859-1)
```

Key invariants a change must not break:

- **One block type per file.** `operadoraParaANS` in the XSD is a `choice`; a CSV mixing `guia`/`fornecimento_direto`/`outra_remuneracao`/`valor_preestabelecido` is rejected before XML generation (`parse-monitoring-csv.js`). Block-to-XML-element mapping lives in `BLOCK_XML_ELEMENTS` (`domain/monitoramento/constants.js`).
- **1:N grouping via `chave_registro`.** Rows sharing a `chave_registro` become one XML record with repeated procedures; all non-item columns must be identical across those rows or the CSV is rejected (`groupRows` in `parse-monitoring-csv.js`). `chave_registro` itself is never emitted to XML.
- **XML element order is load-bearing.** `xml-builder.js` appends fields in exactly the sequence the XSD expects — do not reorder `writer.text`/`writer.optional` calls without checking the XSD, since libxml2 validates sequence, not just presence.
- **Hash semantics.** The MD5 hash is computed over the literal concatenation of leaf element _values_ only (no tag names/attributes, no epilogue), encoded ISO-8859-1. `xml-builder.js` accumulates `hashParts` while writing; `hash-validator.js` independently recomputes it by walking leaf nodes (skipping `epilogo`) for round-trip validation. These two implementations must stay in sync in what they consider a "leaf".
- **Latin-1 only.** `assertLatin1` (in `infrastructure/csv/normalizers.js`) guards every value written into the XML — the output must be representable in ISO-8859-1 end to end.
- **XSD validation is independent of hash validation.** `validate-monitoring-file.js` runs both and ANDs the results; a structurally valid XML can still fail if tampered (see `test/generation.test.js`'s tamper test).
- **External validation has three independent gates.** `xml-decoder.js` checks ISO-8859-1, then XSD and hash are evaluated. Overall validity requires all three. On generated XML, leaf-element source mapping relates residual XSD failures back to CSV line/column/field.
- **Official XSD has a known bug**, worked around at load time only (schema files on disk are untouched): the 202511 ZIP's `tissComplexTypesMonitoramentoV1_06_00.xsd` includes a nonexistent `tissSimpleTypesMonitoramentoV1_05_01.xsd`. `xsd-validator.js` strips that one `<include>` line from the in-memory copy before compiling. See [docs/VALIDACAO_XML_TOOLS.md](docs/VALIDACAO_XML_TOOLS.md).
- **No persistence of assistance data.** HTTP uploads use `multer.memoryStorage()`; the CLI only writes the final `.XTE` to the explicitly given output dir. Logger must never receive CSV rows, XML, or beneficiary data — errors carry structured `details` (line/field/message), not raw payloads.
- **A validated XML is not an ANS protocol.** XSD validity only proves structural conformance — it doesn't check ANS/Receita Federal/IBGE/CNES/TUSS business data. Don't imply otherwise in error messages or docs.

## Where to make specific changes

- Adding/changing a CSV field: `domain/monitoramento/csv-layouts.js` (required/date/decimal/document field sets) → `infrastructure/csv/parse-monitoring-csv.js` (row validation) → `infrastructure/xml/xml-builder.js` (XML emission, matching XSD order) → update `docs/LAYOUT_CSV.md` and the relevant `examples/csv/*.csv`.
- Adding a new block type: touch `BLOCK_TYPES`/`BLOCK_XML_ELEMENTS` in `constants.js`, the layout in `csv-layouts.js`, an `appendX` function in `xml-builder.js`, validation in `validateBlockFields` in `parse-monitoring-csv.js`, and an example CSV.
- CPF/CNPJ rules: `domain/monitoramento/tax-identifiers.js` (mod-11 check digits; CNPJ supports the 12-alphanumeric-plus-2-digit format).
- Schema upgrades: replace files in `schemas/tiss/<version>/`, update `TISS_MONITORING_VERSION` in `constants.js`, and re-check the include-fix workaround in `xsd-validator.js` still applies (or remove it if the new ZIP fixes it).
- Refreshing official ANS artifacts: `npm run ans:download` reads `docs/ans/manifest.json` and pulls files into `docs/ans/originais/` (core) and `var/ans-cache/` (large, opt-in via `--include-large`, gitignored). Don't hand-edit files under `docs/ans/originais/` — they're checksummed against the manifest.

## Conventions

- ESM only (`import`/`export`), Node >= 22.14, no TypeScript.
- Errors: throw `AppError` (or its subclasses `CsvValidationError`, `XmlValidationError` from `shared/errors.js`) for anything user/input-facing; the HTTP error middleware (`interfaces/http/app.js`) and CLI catch blocks both key off `error instanceof AppError` to decide status code / exit behavior vs. generic 500.
- `console.info`/`warn`/`error` are allowed by ESLint (CLI output); everything else goes through the pino logger (`shared/logger.js`).
- Prettier: double quotes, semicolons, trailing commas, 100-col width — run `npm run format` rather than hand-formatting.
- Tests are plain `node:test` + `node:assert/strict`, one file per concern (`test/*.test.js`), driven off the fixtures in `examples/csv/`. Prefer adding a case to the existing example-driven loop pattern (see `test/generation.test.js`) over inventing new fixtures unless the new field genuinely needs its own CSV.

## Unrelated material in this repo

`arq_exemplo/guia_monitoramento_custo_medico.csv` is now the immutable canonical input for the `guia` flow; `examples/csv/guia_monitoramento.csv` must remain byte-identical to it. `sql/select_exportacao_csv.sql` is the protected upstream export contract. Do not modify either file when adapting the importer. Other material under `claude/prompt/` and `docs/modelagem_sys/` remains supporting SPS/MySQL research rather than runtime code.
