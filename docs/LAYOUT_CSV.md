# Layout dos CSVs

## Regras comuns

- codificação: UTF-8, com ou sem BOM; ISO-8859-1 também é aceito;
- delimitador: ponto e vírgula (`;`);
- cabeçalhos: `snake_case`; acentos e espaços são normalizados;
- datas: `AAAA-MM-DD` ou `DD/MM/AAAA`;
- competências: `AAAAMM` ou `MM/AAAA`;
- decimais: `1234.56` ou `1234,56`, sem separador de milhar;
- `tipo_registro`: `1` inclusão, `2` alteração, `3` exclusão;
- cada CSV deve conter apenas um `tipo_bloco`;
- colunas desconhecidas são rejeitadas para detectar erros de digitação no cabeçalho;
- uma `chave_registro` não é enviada ao XML; ela serve apenas para agrupar linhas.

Os cabeçalhos completos e a ordem recomendada estão nos CSVs de [`examples/csv`](../examples/csv).
Para `guia`, o contrato de referência é
[`arq_exemplo/guia_monitoramento_custo_medico.csv`](../arq_exemplo/guia_monitoramento_custo_medico.csv),
mantido byte a byte em `examples/csv/guia_monitoramento.csv`. A rotina e os testes adaptam-se a
esse contrato; o arquivo de referência e `sql/select_exportacao_csv.sql` não devem ser alterados.

## Como os erros são apresentados

A validação ocorre antes da geração e acumula todas as inconsistências detectáveis. Cada item
informa `linha`, `coluna`, `campo`, `localizacao` (`L2:C5`) e `mensagem`. O valor bruto não é
incluído nos logs, evitando exposição de dados assistenciais. São conferidos:

- quantidade e nomes das colunas, campos obrigatórios e um único bloco por arquivo;
- datas reais, mês da competência, inteiros e limites decimais `10,2`/`12,4`;
- tamanhos, padrões e domínios enumerados do XSD;
- CPF/CNPJ, inclusive CNPJ alfanumérico, e compatibilidade ISO-8859-1;
- escolhas mutuamente exclusivas, listas com `|`/`:` e repetição coerente do registro-pai.

Após essas regras, o XML provisório é validado pelo XSD. Se uma restrição residual falhar, a
linha do XML é correlacionada à linha e ao campo de origem no CSV.

## `guia`

Campos obrigatórios do registro:

- controle: `tipo_bloco`, `chave_registro`, `tipo_registro`;
- prestador: `forma_envio`, `executante_cnes`, `executante_tipo_identificacao`, `executante_cpf_cnpj`, `executante_municipio`;
- beneficiário: `beneficiario_sexo`, `beneficiario_data_nascimento`, `beneficiario_municipio_residencia`, `plano_registro`;
- guia: `tipo_evento_atencao`, `origem_evento_atencao`, `numero_guia_prestador`, `numero_guia_operadora`, `identificacao_reembolso`;
- datas: `data_realizacao`, `data_protocolo_cobranca`, `data_processamento_guia`;
- totais: `valor_total_informado`, `valor_processado`, `valor_total_pago_procedimentos`, `valor_total_diarias`, `valor_total_taxas`, `valor_total_materiais`, `valor_total_opme`, `valor_total_medicamentos`, `valor_glosa_guia`, `valor_pago_guia`, `valor_pago_fornecedores`, `valor_total_tabela_propria`, `valor_total_coparticipacao`;
- procedimento: `procedimento_codigo_tabela`, exatamente um entre `procedimento_grupo` e `procedimento_codigo`, `quantidade_informada`, `valor_informado`, `quantidade_paga`, `valor_pago_procedimento`, `valor_pago_fornecedor`, `valor_coparticipacao_procedimento`.

Campos opcionais/condicionados incluem CNS/CPF, versão do prestador, operadora intermediária, contratação preestabelecida, dados de internação, diagnósticos, atendimento, declarações, dente/região, unidade, fornecedor e pacote. Veja o cabeçalho do exemplo para a lista integral.

Listas em uma célula:

```text
formas_remuneracao = 01:100.00|02:50.00
diagnosticos_cid10 = A00|B20
declaracoes_nascido = DN001|DN002
detalhes_pacote = 22:10101012:1.0000:036|19:12345678:2.0000:036
```

`formas_remuneracao` aceita códigos `01` a `07`; diagnósticos aceitam até 4 itens; declarações
de nascido/óbito, até 8. Em `detalhes_pacote`, a tabela deve ser `18`, `19`, `20` ou `22` e a
unidade, quando informada, deve pertencer ao domínio `001` a `061` do XSD.

Para origem `1`, `2` ou `3`, `identificacao_reembolso` deve conter 20 zeros. Para origem `4` ou `5`, deve conter o identificador real.

## `fornecimento_direto`

Obrigatórios:

- `tipo_bloco`, `chave_registro`, `tipo_registro`;
- `beneficiario_sexo`, `beneficiario_data_nascimento`, `beneficiario_municipio_residencia`, `plano_registro`;
- `identificacao_fornecimento_direto`, `data_fornecimento`;
- `valor_total_fornecimento`, `valor_total_tabela_propria`, `valor_total_coparticipacao`;
- `procedimento_codigo_tabela`, exatamente um entre `procedimento_grupo` e `procedimento_codigo`;
- `quantidade_fornecida`, `valor_fornecido`, `valor_coparticipacao_procedimento`.

CNS, CPF e unidade de medida são opcionais/condicionados pelo manual.

## `outra_remuneracao`

Uma linha por `chave_registro`:

- `tipo_bloco`, `chave_registro`, `tipo_registro`;
- `data_processamento`;
- `recebedor_tipo_identificacao`, `recebedor_cpf_cnpj`;
- `valor_total_informado`, `valor_total_glosa`, `valor_total_pago`.

## `valor_preestabelecido`

Uma linha por `chave_registro`:

- `tipo_bloco`, `chave_registro`, `tipo_registro`;
- `competencia_cobertura`;
- `identificacao_valor_preestabelecido`, `valor_preestabelecido`;
- preencha **um** destes caminhos:
  - `prestador_cnes`, `prestador_tipo_identificacao`, `prestador_cpf_cnpj`, `prestador_municipio`; ou
  - `operadora_intermediaria_registro`.

## CNPJ alfanumérico

Os schemas vigentes aceitam CNPJ com 12 caracteres alfanuméricos seguidos por 2 dígitos. Pontuação é removida na importação. O projeto valida localmente tanto o formato quanto os dígitos verificadores pelo módulo 11 divulgado pela Receita Federal; a existência e a situação cadastral dependem das bases externas usadas pela ANS.

Fonte: [Receita Federal — CNPJ alfanumérico](https://www.gov.br/receitafederal/pt-br/acesso-a-informacao/acoes-e-programas/programas-e-atividades/cnpj-alfanumerico).
