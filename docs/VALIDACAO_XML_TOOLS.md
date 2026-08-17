# Validação equivalente ao XML Tools

## Motor

A extensão XML Tools do Notepad++ e este projeto usam o `libxml2` para validar XML contra XSD. O projeto executa o mesmo tipo de validação via `xmllint-wasm` e devolve erros no formato:

```text
[XSD] Linha 51, coluna ?: Element '...': [facet 'enumeration'] ...
```

Execute:

```bash
npm run validar -- caminho/arquivo.XTE
```

O comando ainda valida encoding e hash MD5, etapas que o XSD e o XML Tools não executam:

```text
XML válido no XSD 1.06.00; encoding ISO-8859-1 e hash MD5 conferem.
```

Pela interface web, a mesma rotina fica disponível em **Validar um XTE existente**. Em caso de
hash divergente, o resultado mostra o valor apresentado no epílogo e o MD5 correto calculado.
O cálculo considera a concatenação literal dos valores, sem tags/atributos/epílogo, em
ISO-8859-1; a comparação hexadecimal não diferencia maiúsculas de minúsculas.

## Leitura do diagnóstico

- `[ENCODING]`: declaração ausente/incorreta, BOM UTF-8 ou caractere fora de Latin-1;
- `[XSD]`: linha, coluna quando fornecida pelo libxml2, elemento e regra violada;
- `[HASH]`: hash ausente/malformado ou diferença entre informado e calculado.

Para XML gerado a partir de CSV, erros do XSD incluem também a origem
`CSV:L<linha>:C<coluna>` e o campo. Para XML externo, a localização é a linha do próprio XML.

## Inconsistência no ZIP oficial 202511

O arquivo oficial `tissComplexTypesMonitoramentoV1_06_00.xsd` contém:

```xml
<include schemaLocation="tissSimpleTypesMonitoramentoV1_05_01.xsd"/>
```

Esse arquivo `1_05_01` não existe no ZIP publicado pela ANS. O schema principal já inclui corretamente `tissSimpleTypesMonitoramentoV1_06_00.xsd`.

Os arquivos oficiais são preservados sem alteração em `schemas/tiss/1.06.00`. Durante o carregamento, `xsd-validator.js` remove somente o include obsoleto da cópia em memória. Nenhuma regra, tipo ou enumeração é modificada.

Se o XML Tools informar que não conseguiu carregar `tissSimpleTypesMonitoramentoV1_05_01.xsd`, valide com uma cópia do schema complexo em que apenas essa linha seja removida. Use `tissMonitoramentoV1_06_00.xsd` como schema principal e mantenha os três arquivos no mesmo diretório.

## Resultado válido não é protocolo ANS

`XML is valid` significa conformidade com o XSD. O protocolo de recepção e o arquivo de retorno da ANS continuam sendo as evidências do processamento e da incorporação dos registros.
