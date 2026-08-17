# Arquitetura e decisões

## Fluxo principal

```text
CSV + metadados
      |
      v
normalização e validação por linha
      |
      v
agrupamento por chave_registro
      |
      v
modelo do bloco TISS
      |
      v
XML na ordem exata do XSD -> hash MD5 dos valores -> epílogo
      |
      v
libxml2 + XSD 01.06.00 + mapa XML -> linha/campo CSV
      |
      v
REGANSAAAAMM9999.XTE (ISO-8859-1)
```

## Limites entre camadas

- `domain`: constantes e regras que pertencem ao contrato TISS;
- `application`: coordena casos de uso e não conhece HTTP ou CLI;
- `infrastructure/csv`: adapta o formato tabular ao modelo do caso de uso;
- `infrastructure/xml`: serializa, calcula o hash e conversa com o libxml2;
- `interfaces`: recebe parâmetros, traduz erros e entrega o resultado.

## Decisões de modelagem

### Um bloco por arquivo

No XSD, `operadoraParaANS` é um `choice`: o arquivo contém guias, fornecimento direto, outra remuneração, valor preestabelecido ou sem movimento. Misturar blocos produz um XML estruturalmente inválido; por isso o CSV é rejeitado antes da geração.

### Procedimentos 1:N no CSV

Guias e fornecimentos possuem procedimentos repetíveis. A coluna `chave_registro` identifica o pai. Linhas com a mesma chave são agrupadas; os dados do pai precisam ser idênticos e as colunas de procedimento formam a lista.

### Defesa em duas camadas

O importador espelha as restrições determinísticas do XSD para falhar cedo com
`CSV:L<linha>:C<coluna>`. O gerador também registra a origem de cada elemento-folha. Assim, uma
falha encontrada somente pelo libxml2, como um CBO fora da enumeração oficial, é relacionada ao
campo original sem inserir atributos de rastreamento no XML final.

### Hash

O hash usa a concatenação literal dos valores dos elementos, na ordem do XML, sem nomes de tags ou atributos e sem o epílogo. A codificação da entrada do MD5 é ISO-8859-1. O validador de hash percorre apenas elementos-folha, ignorando a indentação entre tags.

### Validação de arquivo externo

O upload entrega os bytes em memória ao `xml-decoder`. A declaração/BOM e a possibilidade de
representação em ISO-8859-1 são avaliadas antes de XSD e hash. Os três resultados permanecem
separados para distinguir erro de transporte, erro estrutural e alteração de conteúdo.

### Privacidade

O servidor usa `multer.memoryStorage()`. Nada é salvo automaticamente. O CLI só grava o XTE final no diretório explicitamente indicado. Logs não recebem linhas, documentos, XML ou payloads.

## O que o validador local não substitui

O XSD não consulta as bases da ANS, Receita Federal, IBGE, CNES ou as terminologias vigentes da TUSS. O projeto faz validação estrutural e algumas regras determinísticas do manual, mas o arquivo de exemplo deve ser substituído por dados reais e homologado no processo oficial da operadora.
