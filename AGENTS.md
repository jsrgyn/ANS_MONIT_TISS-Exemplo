# Repository Guidelines

## Project Structure & Module Organization

This is a Node.js 22+ ESM service that converts monitoring CSV files into ANS TISS
`.XTE` XML. Code follows a one-way dependency flow: `interfaces` → `application` →
`domain`/`infrastructure`.

- `src/domain/monitoramento/`: layouts, metadata, constants, and business validation.
- `src/application/`: framework-independent generation and validation use cases.
- `src/infrastructure/`: CSV parsing, XML creation, MD5 checking, and XSD validation.
- `src/interfaces/`: CLI commands and the Express HTTP API.
- `public/`: static HTML/CSS/JS UI; no frontend build is required.
- `test/`: tests; `arq_exemplo/` is the immutable canonical guide CSV and `examples/csv/`
  supplies executable fixtures.
- `schemas/` and `docs/ans/`: pinned official schemas and regulatory source artifacts.

## Build, Test, and Development Commands

Install with `npm ci`, copy `.env.example` to `.env`, then use:

- `npm run dev`: start the HTTP server with file watching at `127.0.0.1:3001`.
- `npm start`: run the server without watching.
- `npm test`: run all `node:test` suites.
- `npm run test:coverage`: report built-in test coverage.
- `npm run lint` / `npm run format:check`: verify ESLint and Prettier rules.
- `npm run check`: run linting, formatting checks, and tests; use before submitting.
- `npm run gerar -- --csv examples/csv/guia_monitoramento.csv ...`: generate an XTE.
- `npm run validar -- output/file.XTE`: validate an existing XML/XTE file.

There is no compilation step.

## Coding Style & Naming Conventions

Use ESM `import`/`export`, two-space indentation, double quotes, semicolons, trailing commas,
and a 100-column limit. Run `npm run format` for mechanical formatting. Name modules in
kebab-case, variables/functions in camelCase, and constants in UPPER_SNAKE_CASE. Throw
`AppError` subclasses for user-facing failures. Never log CSV rows, XML, or beneficiary data;
report CSV failures by line, column, and field.

## Testing Guidelines

Tests use `node:test` with `node:assert/strict` and are named `test/<concern>.test.js`. Add
regression tests for every behavior change; prefer existing fixtures and table-driven cases.
Run one suite with `node --test test/generation.test.js`. Preserve XML element order, Latin-1
output, hash semantics, one block type per file, and independent encoding/XSD/hash validation.

## Commit & Pull Request Guidelines

The history currently has only `first commit`, so no formal convention is established. Use
short, imperative subjects such as `Validate grouped procedure headers`. PRs should explain
behavior and regulatory impact, list verification commands, link relevant issues, and include
screenshots only for `public/` UI changes. Update layouts, examples, and documentation together
when CSV fields or schemas change; do not hand-edit checksummed files in `docs/ans/originais/`.
