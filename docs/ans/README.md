# Artefatos oficiais da ANS

Snapshot obtido em **09/08/2026**, exclusivamente de endereços oficiais `gov.br/ans` e `ans.gov.br`.

## Versões

| Componente | Versão |
| --- | --- |
| Organizacional | 202607 |
| Conteúdo e Estrutura | 202511 |
| Representação de Conceitos/TUSS | 202607 |
| Segurança e Privacidade | 202511 |
| Comunicação de Monitoramento | 01.06.00 |

## Organização local

- `originais/`: downloads oficiais compactados ou PDF original;
- `documentos/`: PDF/XLSX extraídos com nomes portáveis;
- `../../schemas/tiss/1.06.00/`: XSD de Monitoramento extraídos sem alteração;
- `manifest.json`: URLs, tamanhos e SHA-256.

O pacote completo da TUSS 202607 e os arquivos auxiliares somam 608.262.115 bytes e não são versionados. Eles foram baixados e validados no cache ignorado `var/ans-cache`; para reproduzir ou conferir o download pelos SHA-256 do manifesto:

```bash
npm run ans:download -- --include-large
```

## Fontes

- [Padrão TISS - Julho/2026](https://www.gov.br/ans/pt-br/assuntos/prestadores/padrao-para-troca-de-informacao-de-saude-suplementar-2013-tiss/padrao-tiss-julho-2026)
- [Histórico de versões](https://www.gov.br/ans/pt-br/assuntos/prestadores/padrao-para-troca-de-informacao-de-saude-suplementar-2013-tiss/padrao-tiss-historico-das-versoes-dos-componentes-do-padrao-tiss)
- [Monitora TISS](https://www.gov.br/ans/pt-br/assuntos/prestadores/padrao-para-troca-de-informacao-de-saude-suplementar-2013-tiss/monitora-tiss)
