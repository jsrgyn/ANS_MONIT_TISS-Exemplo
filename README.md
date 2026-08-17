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

## Manual de operação

### Gerar e validar um XTE pela interface

1. Execute `npm run dev` e abra `http://127.0.0.1:3001`.
2. Informe registro ANS (6 dígitos), competência (`AAAAMM`), lote e sequencial.
3. Selecione o CSV ou marque **sem movimento**.
4. Clique em **Gerar e validar XTE**. O download só é liberado após validar o CSV,
   montar o XML na ordem do XSD e aprovar o schema oficial.
5. Confira no resultado o nome, a quantidade de registros, o hash e o encoding.

Erros de CSV usam a localização `L<linha>:C<coluna>` e o nome da coluna, por exemplo:

```text
L4:C35 — cbo_executante: valor fora do domínio do XSD 01.06.00
```

Corrija o CSV na posição indicada e envie-o novamente. O serviço não corrige, completa nem
descarta dados silenciosamente.

### Validar um XML/XTE de outro sistema

Na seção **Validar um XTE existente**, envie `.XTE` ou `.xml`. O resultado é dividido em três
verificações independentes:

- encoding declarado e conteúdo compatíveis com `ISO-8859-1`;
- estrutura, ordem, tipos e domínios válidos no XSD 01.06.00 via libxml2;
- hash MD5 informado igual ao hash recalculado.

Quando o hash diverge, a tela e a API mostram **hash informado** e **hash calculado correto**.
Um XML só recebe resultado geral válido quando as três verificações passam.

## Geração por linha de comando

```bash
npm run gerar -- \
  --csv arq_exemplo/guia_monitoramento_custo_medico.csv \
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

O contrato canônico de custo médico é
[`arq_exemplo/guia_monitoramento_custo_medico.csv`](arq_exemplo/guia_monitoramento_custo_medico.csv).
Ele é consumido diretamente, sem pré-processamento, e deve permanecer inalterado. O arquivo
[`examples/csv/guia_monitoramento.csv`](examples/csv/guia_monitoramento.csv) é uma cópia byte a
byte usada na regressão automatizada. A consulta `sql/select_exportacao_csv.sql` também é uma
entrada protegida deste fluxo e não é modificada pelo gerador.

Antes de gerar XML, a importação verifica cabeçalho conhecido, campos obrigatórios, domínios,
tamanhos, datas, competências, decimais, CPF/CNPJ, ISO-8859-1, escolhas exclusivas, listas
compostas e consistência das linhas agrupadas. Uma falha impede a geração e informa linha,
coluna e campo. Restrições residuais, como a enumeração extensa de CBO, são verificadas pelo XSD
e mapeadas de volta à origem no CSV.

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

A resposta inclui o nome, hash, resultado XSD e o XTE ISO-8859-1 em Base64. Falhas de CSV
retornam HTTP `422`, código `CSV_INVALIDO` e `details[]` com `linha`, `coluna`, `campo`,
`localizacao` e `mensagem`.

### `POST /api/v1/monitoramento/validar`

`multipart/form-data` com `arquivo` `.XTE` ou `.xml`. Retorna `encoding`, `xsd` e `hash`. Em
`hash`, `informed` preserva o valor do arquivo e `calculated` informa o MD5 correto; o status é
HTTP `200` somente para resultado geral válido e `422` para qualquer divergência.

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
- erro por linha/coluna/campo antes de gerar o XML;
- encoding, XSD e hash conferidos de forma independente;
- upload em memória de XML externo com hash informado e recalculado no resultado.

O hash segue a regra organizacional da ANS: MD5 da concatenação literal dos valores dos
elementos-folha, da esquerda para a direita, sem nomes de tags/atributos e sem o epílogo, usando
bytes ISO-8859-1. Espaços, maiúsculas, acentos e caracteres de controle presentes nos valores
não podem ser ajustados durante o cálculo.
