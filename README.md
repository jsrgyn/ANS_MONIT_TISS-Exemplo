# ANS - Monitoramento TISS

Projeto Node.js para importar CSV, gerar o XML de envio do Monitoramento TISS, calcular o hash MD5 em ISO-8859-1 e validar o resultado contra o schema oficial da ANS.

O projeto foi inspirado no fluxo de `../ANS_SIB-Exemplo`, mas reorganizado em camadas, sem persistir dados assistenciais em disco e com testes executáveis de verdade.

## Versão regulatória adotada

Snapshot consultado em **09/08/2026**:

- publicação vigente: julho/2026;
- Componente Organizacional: `202607`;
- Componente de Conteúdo e Estrutura: `202511`;
- Componente de Segurança e Privacidade: `202511`;
- Componente de Comunicação para Monitoramento: `01.06.00`;
- extensão de envio: `.XTE`;
- nomenclatura: `REGANSAAAAMM9999.XTE`.

Os arquivos oficiais baixados, URLs e SHA-256 estão em [`docs/ans`](docs/ans/README.md). Os três XSD usados em execução ficam em [`schemas/tiss/1.06.00`](schemas/tiss/1.06.00).

> Uma validação XSD bem-sucedida comprova a conformidade estrutural do XML. A aceitação pela ANS também depende de regras de negócio e bases externas, como cadastro da operadora, CNES, CPF/CNPJ, IBGE, competência aberta e códigos TUSS vigentes.

## Requisitos e instalação

- Node.js 22.14 ou superior;
- npm 10 ou superior.

```bash
npm install
cp .env.example .env
npm run check
npm run dev
```

A interface fica em `http://127.0.0.1:3001`.

## Geração por linha de comando

```bash
npm run gerar -- \
  --csv examples/csv/guia_monitoramento.csv \
  --registro-ans 123456 \
  --competencia 202607 \
  --numero-lote LOTE0001 \
  --sequencial 0001 \
  --output output
```

Sem movimento:

```bash
npm run gerar -- \
  --sem-movimento \
  --registro-ans 123456 \
  --competencia 202607 \
  --numero-lote LOTE0002 \
  --sequencial 0002
```

Validar um XTE já existente:

```bash
npm run validar -- output/1234562026070001.XTE
```

## CSVs suportados

O delimitador é `;`. Datas aceitam `AAAA-MM-DD` ou `DD/MM/AAAA`; decimais aceitam ponto ou vírgula. Cada arquivo deve conter somente um `tipo_bloco`:

- `guia`;
- `fornecimento_direto`;
- `outra_remuneracao`;
- `valor_preestabelecido`.

Em guias e fornecimentos, linhas com a mesma `chave_registro` viram um registro XML com vários procedimentos. Todos os campos de cabeçalho devem se repetir com o mesmo valor; apenas as colunas do procedimento podem variar.

Consulte o [layout completo dos CSVs](docs/LAYOUT_CSV.md) e os [arquivos de exemplo](examples/csv).

## API

### `POST /api/v1/monitoramento/gerar`

`multipart/form-data` com:

- `arquivo`: CSV, exceto para sem movimento;
- `registro_ans`: 6 dígitos;
- `competencia`: `AAAAMM` ou `MM/AAAA`;
- `numero_lote`: até 12 caracteres;
- `sequencial_arquivo`: 4 dígitos;
- `sem_movimento`: `true` quando aplicável.

A resposta inclui o nome, hash, resultado XSD e o XTE em Base64.

### `POST /api/v1/monitoramento/validar`

`multipart/form-data` com `arquivo` `.XTE` ou `.xml`. Retorna separadamente o resultado do XSD e do hash.

### `GET /api/v1/health`

Health check com a versão do schema.

## Arquitetura

```text
src/
├── application/       # casos de uso gerar/validar
├── config/            # ambiente
├── domain/            # contrato do Monitoramento e metadados
├── infrastructure/
│   ├── csv/           # leitura, normalização e agrupamento
│   └── xml/           # XML, hash e validação libxml2
├── interfaces/
│   ├── cli/           # comandos npm
│   └── http/          # Express e upload em memória
└── shared/            # erros e log
schemas/                 # XSD oficiais
examples/csv/            # contratos executáveis de exemplo
docs/                    # layout, arquitetura e fontes ANS
test/                    # unidade, integração e regressão XSD
```

Mais detalhes estão em [Arquitetura e decisões](docs/ARQUITETURA.md) e [Validação XML Tools](docs/VALIDACAO_XML_TOOLS.md).

## Qualidade e segurança

```bash
npm test
npm run lint
npm run format:check
npm run test:coverage
```

- upload em memória, sem `filePath` informado pelo cliente;
- limite padrão de 25 MiB;
- sem log do CSV, XML ou dados de beneficiários;
- resposta XTE realmente codificada em ISO-8859-1;
- erro por linha/campo antes de gerar o XML;
- XSD e hash conferidos de forma independente.
