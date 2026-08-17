---
**Documento de Modelagem de Dados**

**Versão:** 2.0 &nbsp;&nbsp; **Data de Publicação:** 10/08/2026 &nbsp;&nbsp; **Data da Revisão (banco vivo):** 11/08/2026

**Responsável pelo Documento:** A definir — v1.0 gerada com apoio de IA a partir de fontes indiretas; v2.0 **revisada e validada contra o banco de dados vivo** (schema `dados`, host `10.0.1.86`), usando a conexão MCP MySQL configurada em `IA/.mcp.json`. Ainda assim, **revisão final do desenvolvedor/DBA responsável é recomendada** antes de qualquer uso em implementação, conforme `db-versionamento-release.md` §16.2.

---

# SPS — Contas Médicas e Autorização

> Modelagem de entidades, atributos e domínios: lote → protocolo → conta médica → procedimentos/anexos/log, e autorização → guia → procedimentos/anexos/log.

---

## 0. Como ler este documento (leia antes do resto)

A v1.0 deste documento foi reconstruída **sem** inspeção direta do banco (não havia conexão MCP MySQL disponível naquela sessão). Nesta revisão (v2.0), o arquivo `.mcp.json` em `IA/.mcp.json` foi localizado e **contém um servidor MCP MySQL real e funcional**, apontando exatamente para o schema citado como pendência (`MYSQL_DB=dados`, host `10.0.1.86`). Isso permitiu conectar diretamente (via cliente `mysql`, mesmas credenciais do `.mcp.json`) e executar `SHOW TABLES`, `SHOW CREATE TABLE`, e consultas em `dominio` / `dominio_valor` / `entidade` para todas as 12 entidades do escopo original.

**Resultado geral da validação**: das 4 tabelas que a v1.0 marcava como 🔴 "não encontrada / proposta", **as 4 existem de fato** no banco — porém com estruturas reais bem diferentes das propostas. A inconsistência de 3 fontes sobre `ie_situacao_autorizacao` (§4.6 da v1.0) foi resolvida: existe um único domínio oficial (`861 — ie_situacao_aut_proc`) compartilhado entre guia e procedimento, com 11 valores reais. Vários domínios que a v1.0 não conseguiu confirmar (origem do procedimento, classificação, tipo de anexo, evento de log, grau de participação TISS) foram totalmente resolvidos.

Mantém-se o esquema de marcadores de confiança, agora com um quarto significado:

| Marcador | Significado |
|----------|--------------|
| ✅ **CONFIRMADO (fonte documental)** | Encontrado literalmente em SQL real (query, trigger, DDL, INSERT) nos arquivos da equipe (v1.0). |
| ✅ **CONFIRMADO (banco vivo 11/08/2026)** | Extraído agora via `SHOW CREATE TABLE` / `SELECT` direto no schema `dados`. Fonte de maior confiança — substitui qualquer marcação anterior em conflito. |
| 🟡 **INFERIDO** | Deduzido por convenção/analogia — não visto literalmente para esta tabela específica, e não coberto pela validação ao vivo desta revisão. |
| 🔴 **PENDENTE** | Ainda não confirmado em nenhuma fonte, incluindo o banco vivo (ex.: domínio existe mas não foi consultado nesta rodada, ou não está catalogado em `dominio_valor`). |
| ⚠️ | Inconsistência ou divergência real encontrada entre fontes — nesta revisão, geralmente entre o comentário de coluna do DDL (`COMMENT`) e a tabela `dominio_valor` (que é a fonte de verdade em tempo de execução). |

A seção 9 foi reescrita: a maior parte do checklist de v1.0 foi **resolvida**; o que resta pendente está listado lá.

---

## 1. Correspondência de nomes (pedido → nome real no sistema) — todas confirmadas no banco vivo

| Nome informado no pedido | Nome real no banco (`dados`) | Observação |
|---|---|---|
| `sps_lote_contas_medicas` | `sps_lote_conta_medica` | ✅ Existe. Plural → singular. |
| `sps_protocolo_contas_medica` | `sps_protocolo_conta_medica` | ✅ Existe. |
| `sps_contas_medica` | `sps_conta_medica` | ✅ Existe. |
| `sps_conta_medica_proc` | `sps_conta_medica_proc` | ✅ Existe, sem alteração de nome. |
| `sps_conta_medica_profissioanal_proc` | `sps_conta_medica_profissional_proc` | ✅ **Existe no banco** (a v1.0 não encontrou em nenhuma fonte documental e propôs uma estrutura fictícia — a estrutura real é bem diferente, ver §5.5). |
| `sps_conta_medica_anexo` | `sps_conta_medica_anexo` | ✅ **Existe no banco.** PK real é `idsps_conta_anexo` (não `idsps_conta_medica_anexo`) — ver §5.6. |
| `sps_conta_medica_log` | `sps_conta_medica_log` | ✅ **Existe no banco** — ver §5.7. |
| `sps_autrozacao` | `sps_autorizacao_guia` | ✅ Confirmado: não existe `sps_autorizacao` isolada; o cabeçalho é `sps_autorizacao_guia`. |
| `sps_autorizacao_guia_proc` | `sps_autorizacao_guia_proc` | ✅ Existe. |
| `sps_autorizacao_guia_anexo` | `sps_autorizacao_guia_anexo` | ✅ **Existe no banco** — ver §6.3. |
| `procedimento` | `procedimento` | ✅ Existe — tabela muito mais rica que o documentado na v1.0 (~50 colunas, ver §7). |
| `sps_autorizacao_guia_log` | `sps_autorizacao_guia_log` | ✅ Existe. |

---

## 2. Visão geral do fluxo (atualizado)

```
                         ┌────────────────────┐
                         │   sps_beneficiario  │
                         └──────────┬──────────┘
                                    │
     ┌──────────────────────────────┼───────────────────────────────┐
     │                              │                                │
     ▼                              ▼                                ▼
┌───────────────────┐   ┌─────────────────────────┐        ┌──────────────────────┐
│ sps_autorizacao_   │   │     sps_conta_medica     │        │  (demonstrativo de   │
│ guia — pedido de   │◄──┼── idsps_autorizacao_guia│        │   pagamento — fora   │
│ autorização        │   │   (guia executada        │        │   do escopo deste     │
│                    │   │    pelo prestador)        │        │   doc: fin_titulo_*) │
└─────────┬──────────┘   └────────────┬─────────────┘        └──────────────────────┘
          │                            │
          ├──< sps_autorizacao_guia_   ├──< sps_conta_medica_proc >── procedimento
          │      proc >── procedimento │
          │                            ├──< sps_conta_medica_profissional_proc
          ├──< sps_autorizacao_guia_   │      (profissional executante, dados denormalizados)
          │      anexo                 │
          │                            ├──< sps_conta_medica_anexo
          └──< sps_autorizacao_guia_   │
                 log ── tipo_historico  └──< sps_conta_medica_log

                                    ▲
                                    │ N:1
                     ┌──────────────┴───────────────┐
                     │  sps_protocolo_conta_medica    │  (agrupa contas médicas para análise/pagamento)
                     └──────────────┬───────────────┘
                                    │ N:1
                     ┌──────────────┴───────────────┐
                     │   sps_lote_conta_medica        │  (agrupa protocolos por competência/prestador)
                     └───────────────────────────────┘

                dominio ──1:N── dominio_valor
     (catálogo transversal — toda coluna ie_* das entidades acima aponta para um iddominio aqui)
```

**Achado principal desta revisão**: a v1.0 listava como pendência "verificar se existe relação direta entre `sps_conta_medica` e `sps_autorizacao_guia`" — **confirmado que existe**: `sps_conta_medica.idsps_autorizacao_guia` (FK) e ainda `idsps_autorizacao_principal` (auto-relacionamento em ambas as tabelas, usado para vincular SADT/honorário em separado à guia principal de internação).

**Leitura do fluxo de negócio** (inalterada da v1.0, confirmada):

1. O prestador solicita autorização de procedimento/internação → gera `sps_autorizacao_guia` (cabeçalho) + `sps_autorizacao_guia_proc` (itens solicitados).
2. A operadora avalia e muda `ie_situacao_autorizacao`; cada mudança de estado é rastreada em `sps_autorizacao_guia_log`.
3. Realizado o atendimento, o prestador fatura a `sps_conta_medica` (a guia executada, **agora ligada de volta à guia de autorização via `idsps_autorizacao_guia`**), com seus procedimentos em `sps_conta_medica_proc`.
4. Contas médicas de um mesmo prestador/competência são agrupadas em `sps_protocolo_conta_medica`, que por sua vez pertence a um `sps_lote_conta_medica`.
5. O protocolo, quando liberado/pago, alimenta o financeiro (`fin_titulo_pagar_lote_conta_medica`, confirmado como entidade real via `entidade.identidade = 1217`; fora do escopo deste documento).

---

## 3. Convenções de nomenclatura e padrões da plataforma

(Fonte: `IA/db-versionamento-release.md`, confirmado pelo DDL real em todas as 12 tabelas)

| Prefixo/padrão | Semântica | Tipo típico confirmado no banco |
|---|---|---|
| `id<tabela>` | Chave primária, auto incremento | `int NOT NULL AUTO_INCREMENT` |
| `id<tabela_referenciada>` | Chave estrangeira | `int`, com `CONSTRAINT ... FOREIGN KEY` explícita |
| `dt_` | Data / data-hora | `date` / `timestamp` (quase sempre `NULL DEFAULT NULL`, exceto `dt_insert`/`dt_update`) |
| `ds_` | Descrição / texto livre | `varchar` / `text` / `longtext` (JSON de log) |
| `nm_` | Nome | `varchar` |
| `cd_` | Código | `varchar`/`char`/`int` (uso de `int` para código é mais comum do que a v1.0 previa, ex.: `cd_cbo`, `cd_procedimento`) |
| `nr_` | Número | `varchar`/`int` |
| `qt_` | Quantidade | `int` |
| `vl_` | Valor monetário | `decimal(10,2)`, quase sempre com `DEFAULT '0.00'` |
| `ie_` | Indicador / enumeração | `char(1)` ou `char(2)` — **confirmado**: quando o domínio tem valores alfabéticos de 2 letras (ex. `DI`, `AM`, `NU`), a coluna é `char(2)`, não `char(1)` |
| `status` | Situação de auditoria padrão da linha | `char(1) NOT NULL DEFAULT 'A'` |
| `dt_insert` / `dt_update` | Auditoria de criação/atualização | `timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP` (`dt_update` quase sempre com `ON UPDATE CURRENT_TIMESTAMP`) — presentes em **todas** as 12 tabelas, sem exceção |

**Padrão de log confirmado** (`sps_conta_medica_log`, `sps_autorizacao_guia_log`): ambos usam o par genérico `identidade` (FK → `entidade.identidade`, identifica QUAL tabela do sistema sofreu a alteração) + `idregistro` (PK do registro alterado nessa tabela) — um padrão de log **polimórfico/genérico**, não um log dedicado por entidade. Isso diverge da proposta 🔴 da v1.0, que assumia uma FK direta e exclusiva `idsps_conta_medica`/`idsps_autorizacao_guia` (essa FK direta *também* existe, como coluna auxiliar, mas o vínculo estrutural do log é via `identidade`/`idregistro`).

**Padrão de profissional executante confirmado**: tanto `sps_conta_medica` quanto `sps_autorizacao_guia` e `sps_conta_medica_profissional_proc` **não usam FK para uma tabela `profissional` como padrão principal** — os dados do profissional (nome, número e UF do conselho, CBO) são **denormalizados diretamente nas colunas** (`nm_profissional`, `nr_conselho`, `sg_conselho`, `uf_conselho`, `cd_cbo`). A única exceção é `sps_autorizacao_guia.idprofissional`, que existe como FK opcional para `profissional` **além** dos campos denormalizados.

Constraints observadas no banco: FK = `<tabela_origem>_<tabela_destino>_FK` (nem sempre `<coluna>` no nome, ex.: `sps_conta_medica_sps_prestador_FK_1` para a segunda FK à mesma tabela) — o padrão `<tabela>_<colunas>_idxu` da v1.0 para índice único não foi observado; os únicos vistos usam `uk_` ou `uq_` como prefixo (ex.: `uk_sps_conta_medica_lote_prestador`, `uq_cd_procedimento_origem`).

---

## 4. Domínios (`dominio` / `dominio_valor`) — totalmente revalidados no banco vivo

### 4.1 Estrutura genérica do catálogo — ✅ CONFIRMADO (banco vivo)

Estrutura real idêntica ao descrito na v1.0 (tabelas `dominio` e `dominio_valor`), incluindo a função `f_dominio_valor_atributo`. Sem alterações.

### 4.2 Domínio padrão de auditoria — `status` (transversal) — inalterado

| Valor | Descrição |
|---|---|
| `A` | Ativo |
| `I` | Inativo |

### 4.3 Domínio **868** — `ie_situacao_lote_conta` (`sps_lote_conta_medica.ie_situacao`) — ✅ CONFIRMADO (banco vivo)

| Valor | Descrição |
|---|---|
| `A` | Aberto |
| `F` | Fechado |
| `P` | Fechado e Pago |

Idêntico à v1.0. Coluna real: `char(1) NOT NULL DEFAULT 'A'`.

### 4.4 Domínio **871** — `ie_situacao_protocolo_conta` (`sps_protocolo_conta_medica.ie_situacao`) — ✅ CONFIRMADO (banco vivo)

| Valor | Descrição |
|---|---|
| `0` | Recebido |
| `1` | Em Análise |
| `2` | Liberado para pagamento |
| `3` | Pago |
| `4` | Finalizado |

Mesmos 5 valores da v1.0 (ordem de exibição diferente — irrelevante). **Pendência da v1.0 resolvida**: o valor `'I'` citado em `query_custo_medico.sql` **não existe** em `dominio_valor` para este domínio — não é um valor de negócio catalogado; ao usar a coluna, considerar apenas `0`–`4`. Coluna real: `char(1) NOT NULL DEFAULT '0'`.

### 4.5 Domínio **870** — `ie_situacao_conta` (`sps_conta_medica.ie_situacao`) — ✅ CONFIRMADO (banco vivo) — ⚠️ **CORRIGE a v1.0**

A v1.0 (§4.5) documentou este campo com valores `L`/`A`/`N`/`P` (Liberada/Em análise/Negada/Paga), a partir de um comentário de query de dashboard. **Isso está incorreto para a coluna real.** O domínio oficial (`870`) é:

| Valor | Descrição |
|---|---|
| `0` | Recebida |
| `1` | Em Análise |
| `2` | Análise Finalizada |
| `3` | Liberada para pagamento |
| `4` | Pago |

Coluna real: `char(1) NOT NULL DEFAULT '0'` — mesmo formato numérico do domínio do protocolo (871), **não** um domínio de letras como a v1.0 supunha. A query-fonte da v1.0 provavelmente usava um alias/coluna calculada de UI (rótulo `L`/`A`/`N`/`P`), não a coluna `ie_situacao` diretamente — **não usar os valores de letra da v1.0 para esta coluna.**

### 4.6 / 4.7 Domínio **861** — `ie_situacao_aut_proc` — ✅ CONFIRMADO (banco vivo) — **resolve a inconsistência entre 3 fontes da v1.0**

A v1.0 relatou três conjuntos de valores divergentes para `sps_autorizacao_guia.ie_situacao_autorizacao` e para `sps_autorizacao_guia_proc.ie_situacao_procedimento`, sem conseguir determinar qual era o oficial. **Existe um único domínio oficial, compartilhado pelas duas colunas** ("Situação da autorização ou do procedimento"):

| Valor | Descrição |
|---|---|
| `DI` | Em Digitação |
| `EM` | Em Auditoria |
| `EA` | Aguardando Análise |
| `AM` | Autorizada pelo Médico Auditor |
| `AA` | Autorizada pelo Usuário Administrativo |
| `AS` | Autorizada pelo Sistema |
| `AU` | Autorizada |
| `NA` | Negada pelo Médico Auditor |
| `NU` | Negada pelo Usuário Administrativo |
| `NS` | Negada pelo Sistema |
| `CA` | Cancelada |

**Conclusão sobre as 3 fontes da v1.0**: a **Fonte A** (`padroes_sql.md`, trigger `sps_autorizacao_guia_dt_autorizacao`) estava certa nos códigos e na lógica de transição — só faltavam os rótulos, agora completos acima. As **Fontes B** (`A`/`N`/`P`/`C`) e **C** (`AU` isolado) referem-se a outro contexto (provável rótulo simplificado de dashboard/relatório, não ao domínio 861 em si) — **não usar B nem C para tomada de decisão sobre este campo.**

Colunas reais: `sps_autorizacao_guia.ie_situacao_autorizacao char(2) NOT NULL DEFAULT 'DI'`; `sps_autorizacao_guia_proc.ie_situacao_procedimento char(2) NOT NULL DEFAULT 'DI'`. A trigger documentada na v1.0 (`sps_autorizacao_guia_dt_autorizacao`) permanece válida — as transições `EM→AM/AA`, `EM→NU/NA`, `DI/EA→CA` fazem sentido com os rótulos acima.

### 4.8 Domínio **864** — `ie_evento_log_autorizacao` (evento de `sps_autorizacao_guia_log.ie_autorizacao_evento_log`) — ✅ CONFIRMADO (banco vivo) — lista completa

A v1.0 só tinha confirmado o valor `6` (Negada). Lista completa:

| Valor | Descrição |
|---|---|
| `1` | Criação da Guia |
| `2` | Envio para Análise |
| `3` | Início da Análise |
| `4` | Transferência da Análise |
| `5` | Autorizada |
| `6` | Negada |
| `7` | Processo Cancelado |
| `8` | Edição da Autorização |
| `9` | Inclusão de Procedimento |
| `10` | Edição de Procedimento |
| `11` | Inclusão de Anexo |
| `12` | Edição do Anexo |
| `13` | Reversão de Autorização |
| `14` | Reversão de Negativa |
| `15` | Inclusão de Procedimento em Lote |

Coluna real: `char(2) NOT NULL` (não `INT` como a v1.0 supunha).

### 4.8b Domínio **874** — `ie_evento_log_conta` (evento de `sps_conta_medica_log`) — ✅ CONFIRMADO (banco vivo) — **novo, não coberto pela v1.0**

⚠️ Nota de nomenclatura real: a coluna que usa este domínio na tabela `sps_conta_medica_log` está fisicamente nomeada `ie_autorizacao_evento_log` (mesmo nome usado no log de autorização) — **atenção ao ler o DDL, não confundir com o domínio 864**; o domínio correto para esta coluna, neste registro, é o `874`.

| Valor | Descrição |
|---|---|
| `0` | Abertura do Lote |
| `1` | Fechamento do Lote |
| `2` | Alteração do Lote |
| `3` | Criação do Protocolo |
| `4` | Alteração do Protocolo |
| `5` | Importação da Conta |
| `6` | Digitação da Conta |
| `7` | Digitação do Procedimento |
| `8` | Alteração do Procedimento |
| `9` | Análise Finalizada |
| `10` | Inserção de Anexo |
| `11` | Alteração da Conta |

### 4.9 Domínio **481** — `ie_origem_proced` (`procedimento.ie_origem_proced`) — ✅ CONFIRMADO (banco vivo) — lista completa

A v1.0 só tinha visto o código `8` sem rótulo. Lista completa (17 valores):

| Valor | Descrição |
|---|---|
| `1` | AMB |
| `2` | SUS-AIH |
| `3` | SUS-BPA |
| `4` | PROPRIO |
| `5` | CBHPM |
| `7` | SUS_2008 |
| `8` | **TUSS** |
| `9` | UV GOA |
| `11` | OPS |
| `13` | EBM |
| `14` | GOA |
| `15` | DRG |
| `16` | DKG-NT |
| `17` | HCPCS |
| `18` | CPT |
| `19` | ACHI |
| `20` | MBS |
| `21` | Presenting illness |

⚠️ Coluna real: `procedimento.ie_origem_proced` é `int DEFAULT NULL` — o próprio comentário do DDL já registra isso como uma divergência de padrão da plataforma (esperado seria `char`/`varchar`). Confirma-se a divergência.

### 4.10 Domínio **513** — `ie_tipo_procedimento` — ✅ CONFIRMADO (banco vivo) — mapa muito mais extenso que a v1.0

A v1.0 listava 24 valores; o domínio real tem **~120 valores** (tabela de especialidades/tipos de procedimento). Os 24 da v1.0 permanecem corretos e são um subconjunto. Amostra adicional relevante não coberta na v1.0: `26` Colonoscopia, `27` Fibrobronscopia, `31` Hemodiálise, `32` Litotripsia, `33` Cardiologia, `34` Radiologia, `74` Anátomo, `75` Biópsia, `92` Endoscopia, `99` Cirúrgico, `101`–`160` (Ginecologia, Plástica, Genética, Angioplastia, Cateterismo, Ablação, Marcapasso, Hidratação, Ecocardiografia, várias cirurgias ortopédicas específicas — Artroplastia de Joelho/Quadril, Artroscopia, Coluna, Escoliose, Trauma —, Odontologia, Terapia Ocupacional, Psicologia). Lista completa disponível em `dominio_valor WHERE iddominio = 513` — recomenda-se consultar diretamente ao invés de embutir os ~120 valores neste documento (ver §9 para a query pronta).

⚠️ Coluna real: `procedimento.ie_tipo_procedimento` é `int DEFAULT NULL` (mesma divergência de tipo do 481 — o próprio comentário do DDL já registra isso).

### 4.11 Domínio **112** — `ie_classificacao` (`procedimento.ie_classificacao`) — ✅ CONFIRMADO (banco vivo) — **resolve pendência da v1.0**, com ⚠️ divergência interna no banco

| Valor | Descrição |
|---|---|
| `1` | Procedimentos |
| `2` | Serviços Hospitalares |
| `3` | Diárias |
| `4` | Materiais e OPME |
| `5` | Medicamentos |
| `6` | Gases Medicinais |

⚠️ O `COMMENT` da própria coluna no DDL (`ie_classificacao char(1) ... COMMENT 'Domínio 112: 1=Procedimentos, 2=Serviços Hospitalares, 3=Diárias.'`) está **desatualizado** — lista só 3 dos 6 valores reais cadastrados em `dominio_valor`. **`dominio_valor` é a fonte de verdade em runtime; o `COMMENT` do DDL é apenas documentação estática e pode ficar defasado** — lição a aplicar a todos os outros comentários de coluna citados neste documento.

### 4.12 `ie_classif_custo` (`procedimento.ie_classif_custo`) — ✅ CONFIRMADO (comentário do DDL) — 🔴 id do domínio ainda não localizado

| Valor | Descrição |
|---|---|
| `A` | Alto |
| `M` | Médio |
| `B` | Baixo |

Coluna real: `char(1) DEFAULT NULL`. Não foi localizado um `iddominio` correspondente nas buscas por nome desta revisão — pode ser um domínio com nome não previsível por convenção, ou um valor fixo em código de aplicação. Ver §9.

### 4.13 Domínio **114** — `ie_alta_complexidade` (`procedimento.ie_alta_complexidade`) — ✅ CONFIRMADO (banco vivo)

| Valor | Descrição |
|---|---|
| `A` | Alta Complexidade |
| `M` | Média Complexidade |
| `B` | Baixa Complexidade |
| `N` | Não Considera |

Idêntico à v1.0 (que não sabia o id do domínio — agora confirmado: **114**, distinto do 112).

### 4.14 `ie_tabela_tuss` — ainda 🔴 PENDENTE (rótulos oficiais ANS domínio nº 87)

Não revalidado nesta rodada contra `dominio_valor` (não fazia parte das buscas por nome desta sessão — os nomes de domínio candidatos não continham "tuss"). Mantém-se a pendência da v1.0: valores vistos em uso (`18`,`19`,`20`,`22`), rótulos oficiais a confirmar contra `docs/ans/documentos/Padrao_TISS_Componente_Conteudo_Estrutura_202511.xlsx` (aba `situaçãoAutorização`) ou, preferencialmente, contra `dominio_valor` no banco vivo (query pronta em §9).

### 4.15 Domínio **863** — `ie_tipo_anexo_autorizacao` (`sps_autorizacao_guia_anexo.ie_tipo_anexo_autorizacao`) — ✅ CONFIRMADO (banco vivo) — **substitui a proposta 🔴 da v1.0**

A v1.0 propunha valores fictícios (`OPME`, `QUIMIO`, `RADIO`, `OUTRAS_DESPESAS`, `SIT_INICIAL`, por analogia com as abas do TISS). **Os valores reais são outros** — documentos clínicos, não categorias por tipo de despesa TISS:

| Valor | Descrição |
|---|---|
| `1` | Laudo Médico |
| `2` | Pedido Médico |
| `3` | Relatório clínico |
| `4` | Exames Anteriores |
| `5` | Resultado de Exames Complementares |
| `6` | Relatório de Internação |
| `7` | Justificativa de Permanência |
| `8` | Parecer do Auditor |
| `9` | Laudo Cirúrgico |

Coluna real: `int NOT NULL`.

### 4.16 Domínio **873** — `ie_grau_participacao_tiss` (`sps_conta_medica_profissional_proc.ie_grau_participacao_tiss`) — ✅ CONFIRMADO (banco vivo) — **substitui a proposta 🔴 da v1.0**

Domínio descrito oficialmente como "Tabela 35 - Terminologia de grau de participação" (TISS/ANS):

| Valor | Descrição |
|---|---|
| `00` | Cirurgião |
| `01` | Primeiro Auxiliar |
| `02` | Segundo Auxiliar |
| `03` | Terceiro Auxiliar |
| `04` | Quarto Auxiliar |
| `05` | Instrumentador |
| `06` | Anestesista |
| `07` | Auxiliar de Anestesista |
| `08` | Consultor |
| `09` | Perfusionista |
| `10` | Pediatra na sala de parto |
| `11` | Auxiliar SADT |
| `12` | Clínico |
| `13` | Intensivista |

Coluna real: `char(2) NOT NULL` (a v1.0 propunha `char(1)` — corrigido).

### 4.17 `sps_conta_medica_anexo.ie_tipo_anexo_conta` — 🔴 PENDENTE (domínio não identificado)

Coluna real existe (`int DEFAULT NULL`), mas nenhum domínio com nome previsível (`ie_tipo_anexo_conta`) foi encontrado em `dominio`. Candidatos genéricos existentes no banco que podem (ou não) ser reaproveitados por esta coluna: domínio `542` (`ie_tipo_anexo`, genérico — Assinatura Digitalizada, Passaporte, Declaração de Saúde, CPF, Contrato, etc.) ou `640` (`ie_tipo_anexo_atendimento` — Resultado de Exames, Fotos de Lesão, Documentos/Laudos, Cartão de Vacina, Chat, Observação, Outros). **Não assumir nenhum dos dois sem confirmar via `f_dominio_valor_atributo` em código de aplicação real** que referencie esta coluna especificamente.

### 4.18 Outros domínios novos identificados no `procedimento` (fora do escopo original, mas presentes na tabela mestre)

Não estavam no pedido original, mas apareceram no DDL real de `procedimento` e são relevantes para qualquer consumo completo da entidade:

| iddominio | Coluna | Confiança | Valores |
|---|---|---|---|
| 113 | `ie_sexo_sus` | ✅ banco vivo | `F` Feminino / `M` Masculino / `I` Indeterminado / `N` Não possui sexo exclusivo / `A` Não Informado |
| 116 | `ie_apuracao_custo` | ✅ banco vivo | `M` Maior Porte / `Q` Quantidade / `R` Regra taxa cirúrgica / `T` Tempo(h) / `U` Tempo(h) Único / `N` Não Calcula |
| 120 | `ie_forma_apresentacao` | ✅ banco vivo | 17 valores (ex.: `1` Quantidade, `2` Período em minutos, `16` Período em horas — lista completa em `dominio_valor WHERE iddominio=120`) |
| 🔴 não localizado | `ie_tipo_despesa_tiss` (também presente em `sps_conta_medica_proc`) | 🟡 comentário do DDL apenas | `1` Gases / `2` Medicamentos / `3` Materiais / `4` Taxas Diversas / `5` Diárias / `6` Aluguel / `7` Órtese / `8` Prótese / `9` Materiais Especiais — não confirmado contra `dominio_valor` nesta rodada |

⚠️ **Achado relevante para governança**: a coluna `procedimento.ie_classificacao_interna` traz no seu `COMMENT` do DDL uma referência a "**Decisão Pendente 4, seção 10.3**" de um documento externo (aparentemente sobre normalização de textos em português/espanhol vindos da diretoria). Essa seção 10.3 **não existe nas fontes localizadas para este documento** — sugere a existência de outro artefato de decisão/documentação (possivelmente de uma sessão de IA anterior) que não foi rastreado aqui. Recomenda-se ao responsável pelo documento localizar esse artefato antes de normalizar ou usar essa coluna.

---

## 5. Entidades — Contas Médicas (estrutura real, banco vivo 11/08/2026)

### 5.1 `sps_lote_conta_medica`

| Seq | Atributo | Tipo real | Not Null | Chave | Domínio | Comentário |
|---|---|---|---|---|---|---|
| 1 | `idsps_lote_conta_medica` | `int AUTO_INCREMENT` | S | PK | | Identificador do lote. |
| 2 | `idestabelecimento` | `int` | S | FK → `estabelecimento` | | Estabelecimento logado que gerou o lote. |
| 3 | `idsps_prestador` | `int` | S | FK → `sps_prestador` | | Prestador do lote. |
| 4 | `ds_lote` | `varchar(120)` | S | | | Descrição do lote — **não estava na v1.0**. |
| 5 | `mes_referencia` | `date` | S | | | Competência do lote. |
| 6 | `dt_fechamento_lote` | `datetime` | N | | | Data/hora de fechamento — **não estava na v1.0**. |
| 7 | `ie_situacao` | `char(1) DEFAULT 'A'` | S | | §4.3 (868) | `A`/`F`/`P`. |
| 8 | `vl_liberado` | `decimal(10,2) DEFAULT 0.00` | N | | | Total liberado dos protocolos. |
| 9 | `vl_glosado` | `decimal(10,2) DEFAULT 0.00` | N | | | Total glosado dos protocolos — **não estava na v1.0**. |
| 10 | `vl_coparticipacao` | `decimal(10,2) DEFAULT 0.00` | N | | | Total de coparticipação — **não estava na v1.0**. |
| 11 | `vl_apresentado` | `decimal(10,2) DEFAULT 0.00` | N | | | Total apresentado — **não estava na v1.0**. |
| 12 | `status` | `char(1) DEFAULT 'A'` | S | | §4.2 | Padrão de auditoria. |
| 13 | `dt_insert` | `timestamp DEFAULT CURRENT_TIMESTAMP` | S | | | Criação. |
| 14 | `dt_update` | `timestamp DEFAULT CURRENT_TIMESTAMP ON UPDATE ...` | S | | | Atualização. |

FKs reais: `idestabelecimento → estabelecimento`, `idsps_prestador → sps_prestador`.

### 5.2 `sps_protocolo_conta_medica`

| Seq | Atributo | Tipo real | Not Null | Chave | Domínio | Comentário |
|---|---|---|---|---|---|---|
| 1 | `idsps_protocolo_conta_medica` | `int AUTO_INCREMENT` | S | PK | | Identificador do protocolo. |
| 2 | `idsps_lote_conta_medica` | `int` | N | FK → `sps_lote_conta_medica` | | Lote do protocolo (nulável — protocolo pode existir sem lote atribuído ainda). |
| 3 | `idsps_prestador` | `int` | N | FK → `sps_prestador` | | Prestador do protocolo. |
| 4 | `idestabelecimento` | `int` | S | FK → `estabelecimento` | | Estabelecimento responsável. |
| 5 | `nr_lote_prestador` | `varchar(12)` | S | | | Número do lote no prestador — parte da chave única com `idestabelecimento`+`idsps_prestador`. |
| 6 | `ie_origem_protocolo` | `char(1)` | S | 🔴 domínio não pesquisado nesta rodada | Origem das contas que compõem o protocolo — **não estava na v1.0**. |
| 7 | `ie_tipo_guia_tiss` | `char(2)` | S | 🔴 domínio não pesquisado nesta rodada | Tipo de guia do protocolo — **não estava na v1.0**. |
| 8 | `ie_situacao` | `char(1) DEFAULT '0'` | S | §4.4 (871) | `0`–`4`. |
| 9 | `dt_recebimento` | `date` | N | | | Recebimento do protocolo pela operadora. |
| 10 | `dt_envio` | `timestamp` | N | | | Envio do arquivo pelo prestador — **não estava na v1.0**. |
| 11 | `dt_inicio_analise` | `timestamp` | N | | | Início da análise — **não estava na v1.0**. |
| 12 | `dt_liberacao_protocolo` | `timestamp` | N | | | Liberação para pagamento — **não estava na v1.0**. |
| 13 | `dt_pagamento_protocolo` | `timestamp` | N | | | Pagamento — confirmado, nome exato igual à v1.0. |
| 14 | `vl_liberado` | `decimal(10,2) DEFAULT 0.00` | N | | | Total liberado das contas. |
| 15 | `vl_glosado` | `decimal(10,2) DEFAULT 0.00` | N | | | Total glosado — **não estava na v1.0**. |
| 16 | `vl_coparticipacao` | `decimal(10,2) DEFAULT 0.00` | N | | | Total de coparticipação — **não estava na v1.0**. |
| 17 | `vl_apresentado` | `decimal(10,2) DEFAULT 0.00` | N | | | Total apresentado — **não estava na v1.0**. |
| 18 | `status` | `char(1) DEFAULT 'A'` | S | | §4.2 | Padrão de auditoria. |
| 19 | `dt_insert` / `dt_update` | `timestamp` | S/N | | | Auditoria. |

Constraint única real: `uk_sps_conta_medica_lote_prestador (idestabelecimento, idsps_prestador, nr_lote_prestador)`.

### 5.3 `sps_conta_medica`

Tabela real com **~55 colunas** (a v1.0 documentava 18). Atributos confirmados que **não** estavam na v1.0 — os mais relevantes para regras de negócio:

| Atributo | Tipo real | Comentário |
|---|---|---|
| `idsps_autorizacao_guia` | `int NULL`, FK → `sps_autorizacao_guia` | **Resolve a pendência crítica da v1.0** — a conta É ligada de volta à guia de autorização que a originou. |
| `idsps_autorizacao_principal` | `int NULL`, FK → `sps_autorizacao_guia` | Guia principal (internação) quando esta conta é SADT/honorário em separado. |
| `idsps_prestador_solic` | `int NULL`, FK → `sps_prestador` | Prestador solicitante (distinto do executante). |
| `idsps_mensalidade_beneficiario` | `int NULL`, FK → `sps_mensalidade_beneficiario` | Rastreia qual mensalidade cobrou a coparticipação desta conta. |
| `ds_indicacao_clinica`, `ds_observacao`, `ds_senha`, `dt_validade_senha` | diversos | Campos de senha/indicação clínica da autorização vinculada. |
| `dt_inicio_analise`, `dt_fim_analise`, `dt_pagamento` | `timestamp` | Datas de ciclo de vida da análise — mais granular que a v1.0. |
| `cd_cbo`, `nm_profissional`, `nr_conselho`, `sg_conselho` (default `'CRM'`), `uf_conselho` (default `'GO'`) | diversos | Profissional executante **denormalizado** (ver §3). |
| `ie_atendimento_particular`, `ie_atendimento_rn`, `ie_carater_atendimento_tiss`, `ie_cobertura_especial_tiss`, `ie_indicador_acidente_tiss`, `ie_origem_conta`, `ie_regime_atendimento_tiss`, `ie_regime_internacao`, `ie_saude_ocupacional_tiss`, `ie_tipo_atendimento_tiss`, `ie_tipo_consulta`, `ie_tipo_guia_tiss`, `ie_tipo_internacao_tiss`, `ie_declaracao_obito_rn`, `ie_motivo_encerramento_tiss`, `ie_tipo_faturamento_tiss` | `char(1)`/`char(2)` | Conjunto completo de indicadores TISS da guia de internação/SADT — **nenhum estava na v1.0**; domínios ainda não pesquisados nesta rodada (🔴). |
| `cd_cid_doenca_princ`, `cd_cid_doenca_seg`, `cd_cid_doenca_terc`, `cd_cid_doenca_quar`, `cd_cid_doenca_obito` | `varchar(4)` | CID principal + até 3 secundários + CID de óbito — a v1.0 só documentava o principal. |
| `dt_inicio_faturamento`, `dt_fim_faturamento`, `hr_inicio_faturamento`, `hr_fim_faturamento` | `date`/`time` | Período faturado. |
| `nr_declaracao_nascido_vivo`, `nr_declaracao_obito` | `varchar(11)` | Documentos oficiais (SINASC/SIM). |
| `dt_alta` | `date` | Data de alta do paciente. |

Atributos confirmados que **coincidem** com a v1.0 (nome e propósito): `idsps_conta_medica` (PK), `idsps_protocolo_conta_medica`, `idsps_beneficiario`, `idsps_prestador_exec`, `nr_guia_prestador`, `dt_autorizacao`, `dt_insert`, `vl_apresentado`, `vl_liberado`, `vl_glosado`, `vl_coparticipacao`, `ie_situacao` (⚠️ valores corrigidos, ver §4.5), `status`. `idsps_beneficiario_titular` **não existe** como coluna própria nesta tabela (não confirmado no DDL real — se necessário, buscar via `sps_beneficiario`).

FKs reais completas: `idestabelecimento → estabelecimento`; `idsps_autorizacao_guia → sps_autorizacao_guia`; `idsps_autorizacao_principal → sps_autorizacao_guia`; `idsps_beneficiario → sps_beneficiario`; `idsps_prestador_solic → sps_prestador`; `idsps_prestador_exec → sps_prestador`; `idsps_mensalidade_beneficiario → sps_mensalidade_beneficiario`; `idsps_protocolo_conta_medica → sps_protocolo_conta_medica`.

### 5.4 `sps_conta_medica_proc`

Divergências relevantes vs. a v1.0 (que era majoritariamente 🟡 inferida por simetria):

| Atributo real | Divergência vs. v1.0 |
|---|---|
| `qt_solicitada`, `qt_autorizada`, `qt_realizada` (NOT NULL) | v1.0 propunha um único `qt_procedimento` 🟡 — na realidade são **3 colunas** de quantidade, com `qt_realizada` obrigatória. |
| `vl_unitario`, `vl_total_apresentado`, `vl_total_aprovado`, `vl_glosado`, `vl_coparticipacao` | v1.0 usava `vl_apresentado`/`vl_liberado` (nomes inferidos, errados) — os nomes reais têm o prefixo `vl_total_` para apresentado/aprovado, mais um `vl_unitario` que não existia na v1.0. |
| `dt_realizacao`, `hr_inicial`, `hr_final` | Não estavam na v1.0 — data e hora de execução do procedimento. |
| `ie_via_acesso_tiss`, `ie_tipo_despesa_tiss`, `ie_tipo_tecnica_tiss` | Não estavam na v1.0 — indicadores TISS adicionais do item. |
| `fator_reducao_acrescimo` (`decimal(10,2) DEFAULT 1.00`) | Não estava na v1.0. |
| `cd_unidade_medida`, `ds_unidade_medida`, `idtiss_unidade_medida` (FK → `tiss_unidade_medida`) | Não estavam na v1.0 — nova tabela de referência `tiss_unidade_medida` identificada. |
| `idsps_mensalidade_beneficiario` (FK) | Não estava na v1.0 — mesmo padrão de rastreio de coparticipação de `sps_conta_medica`. |
| `ie_tabela_tuss` (`char(2) NOT NULL`) | Confirmado, igual à v1.0 (mas era 🟡 inferida, agora ✅). |

Atributos confirmados iguais à v1.0: `idsps_conta_medica_proc` (PK), `idsps_conta_medica` (FK), `idprocedimento` (FK), `status`, `dt_insert`, `dt_update`.

### 5.5 `sps_conta_medica_profissional_proc` — ✅ EXISTE (a v1.0 marcava como 🔴 proposta) — estrutura real bem diferente da proposta

A v1.0 propunha uma tabela de associação com FK para uma tabela `profissional` e um campo `vl_honorario`. **A estrutura real é outra**: dados do profissional **denormalizados** (mesmo padrão de `sps_conta_medica`, ver §3), sem `vl_honorario`.

| Seq | Atributo | Tipo real | Not Null | Chave | Domínio |
|---|---|---|---|---|---|
| 1 | `idsps_conta_medica_profissional_proc` | `int AUTO_INCREMENT` | S | PK | |
| 2 | `idsps_conta_medica_proc` | `int` | S | FK → `sps_conta_medica_proc` | |
| 3 | `cd_contratado_executante` | `varchar(14)` | S | | Código na operadora ou CPF do profissional executante. |
| 4 | `nm_profissional` | `varchar(70)` | S | | Nome do profissional (denormalizado, não FK). |
| 5 | `nr_conselho` | `int` | S | | Registro no conselho. |
| 6 | `sg_conselho` (default `'CRM'`) | `varchar(10)` | S | | Sigla do conselho. |
| 7 | `uf_conselho` (default `'GO'`) | `char(2)` | N | | UF do conselho. |
| 8 | `cd_cbo` | `int` | S | FK → `cbo` | CBO do profissional — **é FK real**, não apenas indicador. |
| 9 | `ds_cbo` | `varchar(80)` | N | | Descrição do CBO (denormalizada). |
| 10 | `ie_grau_participacao_tiss` | `char(2) NOT NULL` | S | §4.16 (873) | Grau de participação (Tabela 35 TISS). |
| 11 | `status` | `char(1) DEFAULT 'A'` | S | §4.2 | |
| 12 | `dt_insert` / `dt_update` | `timestamp` | S/N | | |

Não existe `vl_honorario` nem FK para uma tabela `profissional` — remover essa expectativa de qualquer implementação baseada na v1.0.

### 5.6 `sps_conta_medica_anexo` — ✅ EXISTE (a v1.0 marcava como 🔴 proposta) — nomes de coluna divergentes da proposta

⚠️ **PK real é `idsps_conta_anexo`**, não `idsps_conta_medica_anexo` como a convenção/proposta da v1.0 assumia.

| Seq | Atributo | Tipo real | Not Null | Chave | Domínio |
|---|---|---|---|---|---|
| 1 | `idsps_conta_anexo` | `int AUTO_INCREMENT` | S | **PK** (nome real, atenção) | |
| 2 | `idsps_conta_medica` | `int` | S | FK → `sps_conta_medica` | |
| 3 | `ie_tipo_anexo_conta` | `int` | N | 🔴 domínio não identificado (§4.17) | |
| 4 | `nm_arquivo` | `varchar(255)` | N | | Nome do arquivo (a v1.0 chamava de `nm_arquivo_original`). |
| 5 | `url_ds_anexo` | `varchar(255)` | N | | URL/endereço do arquivo (a v1.0 chamava de `url_arquivo`). |
| 6 | `tipo_arquivo` | `varchar(100)` | N | | Tipo/MIME do arquivo — não estava na v1.0. |
| 7 | `ds_observacao` | `varchar(500)` | N | | Observação — igual à v1.0. |
| 8 | `status` | `char(1) DEFAULT 'A'` | S | §4.2 | |
| 9 | `dt_insert` / `dt_update` | `timestamp` | S/N | | |

**Não existem** os campos `cd_hash_sha256` nem `qt_tamanho_byte` propostos pela v1.0 — não implementar checagem de integridade assumindo esses campos sem antes adicioná-los via migração, se necessário.

### 5.7 `sps_conta_medica_log` — ✅ EXISTE (a v1.0 marcava como 🔴 proposta) — padrão de log genérico/polimórfico confirmado

| Seq | Atributo | Tipo real | Not Null | Chave | Domínio |
|---|---|---|---|---|---|
| 1 | `idsps_conta_medica_log` | `int AUTO_INCREMENT` | S | PK | |
| 2 | `identidade` | `int` | S | FK → `entidade.identidade` | Qual entidade do sistema foi alterada (padrão polimórfico, ver §3). |
| 3 | `idregistro` | `int` | S | | PK do registro alterado nessa entidade. |
| 4 | `idsps_conta_medica` | `int` | N | FK → `sps_conta_medica` | Vínculo direto auxiliar (além do polimórfico). |
| 5 | `idsps_lote_conta_medica` | `int` | N | FK → `sps_lote_conta_medica` | Não estava na v1.0. |
| 6 | `idsps_protocolo_conta_medica` | `int` | N | FK → `sps_protocolo_conta_medica` | Não estava na v1.0. |
| 7 | `ie_autorizacao_evento_log` ⚠️ nome físico | `char(2) NOT NULL` | S | §4.8b (**874**, não 864 — ver nota de nomenclatura) | Evento que gerou o log. |
| 8 | `login` | `varchar(45)` | S | | Usuário responsável. |
| 9 | `nr_sequencia` | `int NOT NULL` | S | | Sequência do log — não estava na v1.0. |
| 10 | `vl_antigo` | `longtext` | N | | Snapshot JSON antes. |
| 11 | `vl_novo` | `longtext NOT NULL` | S | | Snapshot JSON depois — a v1.0 assumia nulável, na realidade é obrigatório. |
| 12 | `ds_observacao` | `varchar(2000)` | N | | Observação/justificativa. |
| 13 | `status` | `char(1) DEFAULT 'A'` | S | §4.2 | Não estava na v1.0. |
| 14 | `dt_insert` / `dt_update` | `timestamp` | S/N | | |

---

## 6. Entidades — Autorização (estrutura real, banco vivo 11/08/2026)

### 6.1 `sps_autorizacao_guia`

Tabela real com **~40 colunas** (a v1.0 documentava 11). Atributos confirmados que **não** estavam na v1.0:

| Atributo | Tipo real | Comentário |
|---|---|---|
| `idsps_autorizacao_principal` | `int NULL`, FK (auto-relacionamento) | Guia principal quando esta é SADT/honorário em separado — mesmo padrão de `sps_conta_medica`. |
| `idprofissional` | `int NULL`, FK → `profissional` | **Único ponto do escopo onde existe FK real para `profissional`** (além dos campos denormalizados abaixo). |
| `idespecialidade` | `int NULL`, FK → `especialidade` | Especialidade do profissional. |
| `idclassificacao_atendimento` | `int NULL`, FK → `classificacao_atendimento` | Classificação/tipo de consulta da guia. |
| `idsps_acomodacao_solicitada`, `idsps_acomodacao_autorizada` | `int NULL`, FK → `sps_acomodacao_categoria` | Acomodação de internação solicitada vs. autorizada. |
| `cd_cbo`, `nm_profissional`, `nr_conselho`, `sg_conselho` (default `'CRM'`), `uf_conselho` (default `'GO'`) | diversos | Profissional executante denormalizado (mesmo padrão de `sps_conta_medica`). |
| `dt_internacao`, `dt_previsao_internacao`, `dt_pedido_medico` | `date` | Datas específicas de internação/pedido médico. |
| `qt_diarias_solicitadas`, `qt_diarias_autorizadas` | `int` | Diárias de internação. |
| `ie_previsao_opme`, `ie_previsao_quimioterapico` (default `'N'`) | `char(1)` | Flags de previsão de uso — não estavam na v1.0. |
| `ie_atendimento_particular`, `ie_atendimento_rn`, `ie_carater_atendimento_tiss`, `ie_cobertura_especial_tiss`, `ie_indicador_acidente_tiss`, `ie_regime_atendimento_tiss`, `ie_regime_internacao`, `ie_saude_ocupacional_tiss`, `ie_tipo_atendimento_tiss`, `ie_tipo_consulta`, `ie_tipo_internacao_tiss` | `char(1)`/`char(2)` | Conjunto de indicadores TISS da solicitação, simétrico ao de `sps_conta_medica` — domínios ainda 🔴 não pesquisados nesta rodada. |
| `ds_senha`, `dt_validade_senha` | `varchar(60)`/`date` | Senha de autorização e validade. |

Atributos confirmados e coincidentes com a v1.0: `idsps_autorizacao_guia` (PK), `idsps_beneficiario`, `idestabelecimento`, `ie_situacao_autorizacao` (⚠️ domínio corrigido, ver §4.6), `ie_tipo_guia_tiss`, `ie_tipo_atendimento_tiss`, `dt_insert`, `dt_autorizacao`, `dt_negado`, `dt_cancelamento`, `status`. `idsps_prestador` é `NOT NULL` (confirmado) — a v1.0 não a documentava (usava `idestabelecimento` como se fosse o prestador solicitante; na realidade são colunas distintas: `idestabelecimento` é o estabelecimento logado, `idsps_prestador` é o prestador que executará o atendimento).

A **trigger `sps_autorizacao_guia_dt_autorizacao`** documentada na v1.0 permanece coerente com os valores reais confirmados do domínio 861 (§4.6) — sem alteração necessária na lógica descrita.

### 6.2 `sps_autorizacao_guia_proc`

Estrutura confirmada **idêntica** à v1.0 em todos os atributos, incluindo nomes e tipos: `idsps_autorizacao_guia_proc` (PK), `idsps_autorizacao_guia` (FK), `idprocedimento` (FK), `ie_tabela_tuss char(2) NOT NULL`, `qt_solicitada int NOT NULL`, `qt_autorizada int NULL`, `dt_autorizacao`, `dt_negado`, `ie_situacao_procedimento char(2) DEFAULT 'DI'` (§4.6/861), `status`, `dt_insert`, `dt_update`. Constraint única real confirmada: `uk_guia_procedimento (idsps_autorizacao_guia, idprocedimento)` — não documentada na v1.0.

### 6.3 `sps_autorizacao_guia_anexo` — ✅ EXISTE (a v1.0 marcava como 🔴 proposta)

| Seq | Atributo | Tipo real | Not Null | Chave | Domínio |
|---|---|---|---|---|---|
| 1 | `idsps_autorizacao_guia_anexo` | `int AUTO_INCREMENT` | S | PK (nome confirmado igual à v1.0) | |
| 2 | `idsps_autorizacao_guia` | `int` | N | FK → `sps_autorizacao_guia` | |
| 3 | `ie_tipo_anexo_autorizacao` | `int NOT NULL` | S | §4.15 (863) | Ver lista real de 9 valores — substitui a proposta OPME/QUIMIO/RADIO da v1.0. |
| 4 | `nm_arquivo` | `varchar(255) NOT NULL` | S | | (v1.0: `nm_arquivo_original`, nulável — na realidade é obrigatório). |
| 5 | `url_anexo` | `varchar(255)` | N | | (v1.0: `url_arquivo`). |
| 6 | `tipo_arquivo` | `varchar(100) NOT NULL` | S | | Não estava na v1.0. |
| 7 | `ds_observacao` | `varchar(500)` | N | | Igual à v1.0. |
| 8 | `status` | `char(1) DEFAULT 'A'` | S | §4.2 | |
| 9 | `dt_insert` / `dt_update` | `timestamp` | S/N | | |

### 6.4 `sps_autorizacao_guia_log`

Mesmo padrão polimórfico de `sps_conta_medica_log` (§5.7): usa `identidade` (FK → `entidade`) + `idregistro`, além do vínculo direto `idsps_autorizacao_guia`.

| Seq | Atributo | Tipo real | Not Null | Chave | Domínio |
|---|---|---|---|---|---|
| 1 | `idsps_autorizacao_guia_log` | `int AUTO_INCREMENT` | S | PK — nome confirmado (v1.0 tinha marcado como 🟡 inferido). | |
| 2 | `identidade` | `int` | S | FK → `entidade.identidade` | Não estava na v1.0. |
| 3 | `idregistro` | `int` | S | | Não estava na v1.0. |
| 4 | `idsps_autorizacao_guia` | `int` | S | FK → `sps_autorizacao_guia` | Igual à v1.0. |
| 5 | `idtipo_historico` | `int` | N | FK → `tipo_historico` | Igual à v1.0. |
| 6 | `ie_autorizacao_evento_log` | `char(2) NOT NULL` | S | §4.8 (864) | Igual à v1.0 no nome; agora com lista completa de 15 valores. |
| 7 | `login` | `varchar(45)` | S | | Não estava na v1.0. |
| 8 | `nr_sequencia` | `int NOT NULL` | S | | Não estava na v1.0. |
| 9 | `vl_antigo` | `mediumtext` | N | | Não estava na v1.0 (tabela irmã já tinha esse padrão). |
| 10 | `vl_novo` | `mediumtext NOT NULL` | S | | Não estava na v1.0. |
| 11 | `ds_observacao` | `varchar(2000)` | N | | Igual à v1.0 (tipo maior: 2000 vs. 1000 proposto). |
| 12 | `status` | `char(1) DEFAULT 'A'` | S | §4.2 | Não estava na v1.0. |
| 13 | `dt_insert` / `dt_update` | `timestamp` | S/N | | Não estava na v1.0. |

A query real de uso documentada na v1.0 (filtro por `ie_autorizacao_evento_log = 6` e `ie_situacao_autorizacao IN ('NS','NU','NA')`) permanece **coerente e válida** com os domínios agora confirmados (864 e 861).

---

## 7. Entidade — Procedimento (estrutura real, banco vivo 11/08/2026) — tabela muito mais rica que a v1.0

A tabela real tem **~50 colunas**; a v1.0 documentava 11. Atributos confirmados que coincidem: `idprocedimento` (PK), `cd_procedimento` (⚠️ tipo real é `int`, não `varchar(10)` como a v1.0 supunha), `ds_procedimento`, `ds_procedimento_interno`, `ie_origem_proced` (⚠️ tipo real `int`, ver §4.9), `ie_tabela_tuss`, `ie_tipo_procedimento` (⚠️ tipo real `int`, ver §4.10), `ie_classificacao` (ver §4.11), `ie_classif_custo` (ver §4.12), `ie_alta_complexidade` (ver §4.13), `status`, `dt_insert`, `dt_update`.

Atributos confirmados que **não** estavam na v1.0 (lista completa, agrupada por função):

**Relacionamentos com outras tabelas mestre** (todas confirmadas via FK real):
- `idsetor_exclusico` → tabela de Setor *(⚠️ nome da coluna no banco tem erro de digitação — deveria ser `idsetor_exclusivo`; sem constraint de FK formal)*
- `cd_doenca_cid`, `cd_cid_secundario` → `cid_doenca`
- `idgrupo_proc` → `grupo_proc`
- `idgrupo_sus` → grupo SUS *(sem constraint de FK formal no banco)*
- `idkit_material` → `kit_material`
- `idproc_cih` → `cih_procedimento`
- `idgrupo_rec` → `grupo_receita`
- `idmedicamento_padrao` → `medicamento_padrao` (usada quando `ie_tabela_tuss = 20`, ou seja, procedimento do tipo Medicamento)

**Textos e orientações**: `ds_complemento`, `ds_complemento_sus`, `ds_orientacao`, `ds_orientacao_sms`, `ds_origem_proced`, `ds_prescricao`, `ds_tipo_vasectomia`.

**Indicadores adicionais (todos `char(1)`, a maioria `S`/`N` sem domínio catalogado)**: `ie_alto_custo_ipasgo`, `ie_ativ_prof_bpa` (E/N/P), `ie_credenciamento_sus` (P/M), `ie_estadio`, `ie_exige_autor_sus`, `ie_exige_lado`, `ie_exige_laudo`, `ie_exige_peso_agenda`, `ie_gera_associado`, `ie_ignora_origem`, `ie_odontologico`, `ie_porte_cirurgia` (E/G/M/P/S), `ie_protocolo_tev`, `ie_util_prescricao`, `ie_valor_especial`.

**Indicadores com domínio catalogado confirmado** (ver §4.18): `ie_sexo_sus` (113), `ie_apuracao_custo` (116), `ie_forma_apresentacao` (120).

**Indicador com domínio parcialmente confirmado** (apenas via `COMMENT`, não via `dominio_valor`): `ie_tipo_despesa_tiss` (`int`) — valores 1–9 no comentário do DDL.

**`ie_especialidade_aih`** (`int`): valores 1–9 documentados diretamente no `COMMENT` do DDL (Cirurgia geral, Obstetrícia, Clínica médica, Crônico, Psiquiatria, Tisiologia, Pediatria, Psiquiatria Hosp Dia) — não confirmado se existe `dominio_valor` catalogado ou se é lista fixa em código.

**Quantidades e limites**: `nr_proc_interno`, `qt_dia_internacao_sus`, `qt_exec_barra`, `qt_hora_baixar_prescr`, `qt_idade_maxima_sus`, `qt_idade_minima`, `qt_max_procedimento`.

**Classificação interna proprietária**: `ie_classificacao_interna` (`char(2)`) — ver nota de governança em §4.18 sobre a referência a "Decisão Pendente 4" encontrada no `COMMENT` desta coluna.

Índices reais relevantes não documentados na v1.0: `uq_cd_procedimento_origem (cd_procedimento, ie_origem_proced)` (chave única composta — um mesmo `cd_procedimento` pode se repetir para origens diferentes) e `procedimento_tuss_origem_status_ds_idx (ie_tabela_tuss, ie_origem_proced, status, ds_procedimento, idprocedimento)`, que sugere ser o índice usado nas telas de busca/autocomplete de procedimento.

---

## 8. Relacionamentos (FK) — resumo consolidado (banco vivo)

| Tabela origem | Coluna | Tabela destino | Confiança |
|---|---|---|---|
| `sps_protocolo_conta_medica` | `idsps_lote_conta_medica` | `sps_lote_conta_medica` | ✅ banco vivo |
| `sps_protocolo_conta_medica` | `idsps_prestador` | `sps_prestador` | ✅ banco vivo |
| `sps_protocolo_conta_medica` | `idestabelecimento` | `estabelecimento` | ✅ banco vivo |
| `sps_conta_medica` | `idsps_protocolo_conta_medica` | `sps_protocolo_conta_medica` | ✅ banco vivo |
| `sps_conta_medica` | `idsps_autorizacao_guia` | `sps_autorizacao_guia` | ✅ banco vivo — **pendência da v1.0 resolvida** |
| `sps_conta_medica` | `idsps_autorizacao_principal` | `sps_autorizacao_guia` | ✅ banco vivo — **novo, não estava na v1.0** |
| `sps_conta_medica` | `idsps_beneficiario` | `sps_beneficiario` | ✅ banco vivo |
| `sps_conta_medica` | `idsps_prestador_exec` | `sps_prestador` | ✅ banco vivo |
| `sps_conta_medica` | `idsps_prestador_solic` | `sps_prestador` | ✅ banco vivo — novo |
| `sps_conta_medica` | `idsps_mensalidade_beneficiario` | `sps_mensalidade_beneficiario` | ✅ banco vivo — novo |
| `sps_conta_medica_proc` | `idsps_conta_medica` | `sps_conta_medica` | ✅ banco vivo |
| `sps_conta_medica_proc` | `idprocedimento` | `procedimento` | ✅ banco vivo |
| `sps_conta_medica_proc` | `idtiss_unidade_medida` | `tiss_unidade_medida` | ✅ banco vivo — novo |
| `sps_conta_medica_proc` | `idsps_mensalidade_beneficiario` | `sps_mensalidade_beneficiario` | ✅ banco vivo — novo |
| `sps_conta_medica_profissional_proc` | `idsps_conta_medica_proc` | `sps_conta_medica_proc` | ✅ banco vivo |
| `sps_conta_medica_profissional_proc` | `cd_cbo` | `cbo` | ✅ banco vivo — novo |
| `sps_conta_medica_anexo` | `idsps_conta_medica` | `sps_conta_medica` | ✅ banco vivo |
| `sps_conta_medica_log` | `identidade` | `entidade` | ✅ banco vivo — novo (padrão polimórfico) |
| `sps_conta_medica_log` | `idsps_conta_medica` | `sps_conta_medica` | ✅ banco vivo |
| `sps_conta_medica_log` | `idsps_lote_conta_medica` | `sps_lote_conta_medica` | ✅ banco vivo — novo |
| `sps_conta_medica_log` | `idsps_protocolo_conta_medica` | `sps_protocolo_conta_medica` | ✅ banco vivo — novo |
| `sps_autorizacao_guia` | `idsps_beneficiario` | `sps_beneficiario` | ✅ banco vivo |
| `sps_autorizacao_guia` | `idsps_prestador` | `sps_prestador` | ✅ banco vivo |
| `sps_autorizacao_guia` | `idsps_autorizacao_principal` | `sps_autorizacao_guia` | ✅ banco vivo — novo (auto-relacionamento) |
| `sps_autorizacao_guia` | `idprofissional` | `profissional` | ✅ banco vivo — novo |
| `sps_autorizacao_guia` | `idespecialidade` | `especialidade` | ✅ banco vivo — novo |
| `sps_autorizacao_guia` | `idclassificacao_atendimento` | `classificacao_atendimento` | ✅ banco vivo — novo |
| `sps_autorizacao_guia` | `idsps_acomodacao_solicitada` / `idsps_acomodacao_autorizada` | `sps_acomodacao_categoria` | ✅ banco vivo — novo |
| `sps_autorizacao_guia` | `cd_cbo` | `cbo` | ✅ banco vivo — novo |
| `sps_autorizacao_guia_proc` | `idsps_autorizacao_guia` | `sps_autorizacao_guia` | ✅ banco vivo |
| `sps_autorizacao_guia_proc` | `idprocedimento` | `procedimento` | ✅ banco vivo |
| `sps_autorizacao_guia_anexo` | `idsps_autorizacao_guia` | `sps_autorizacao_guia` | ✅ banco vivo |
| `sps_autorizacao_guia_log` | `idsps_autorizacao_guia` | `sps_autorizacao_guia` | ✅ banco vivo |
| `sps_autorizacao_guia_log` | `idtipo_historico` | `tipo_historico` | ✅ banco vivo |
| `sps_autorizacao_guia_log` | `identidade` | `entidade` | ✅ banco vivo — novo (padrão polimórfico) |
| `procedimento` | `cd_doenca_cid` / `cd_cid_secundario` | `cid_doenca` | ✅ banco vivo — novo |
| `procedimento` | `idgrupo_proc` | `grupo_proc` | ✅ banco vivo — novo |
| `procedimento` | `idkit_material` | `kit_material` | ✅ banco vivo — novo |
| `procedimento` | `idproc_cih` | `cih_procedimento` | ✅ banco vivo — novo |
| `procedimento` | `idgrupo_rec` | `grupo_receita` | ✅ banco vivo — novo |
| `procedimento` | `idmedicamento_padrao` | `medicamento_padrao` | ✅ banco vivo — novo |
| `dominio_valor` | `iddominio` | `dominio` | ✅ banco vivo |

**Códigos de entidade confirmados** (`entidade.identidade`, usados no padrão de log polimórfico): `1147` lote, `1148` protocolo, `1149` conta médica, `1150` conta_medica_proc, `1153` conta_medica_anexo, `1154` conta_medica_log, `1156` conta_medica_profissional_proc, `1120` autorizacao_guia, `1121` autorizacao_guia_proc, `1122` autorizacao_guia_anexo, `1123` autorizacao_guia_log, `1124` autorizacao_guia_log_json, `1152` autorizacao_guia_cancelar, `1217` fin_titulo_pagar_lote_conta_medica (ponto de integração financeira citado na v1.0, agora confirmado como entidade real).

---

## 9. Pendências de validação — atualizado após revisão no banco vivo

**Resolvidas nesta revisão** (constavam como pendência crítica na v1.0):
- ✅ Valores reais de `ie_situacao_autorizacao`/`ie_situacao_procedimento` — domínio único `861`, 11 valores (§4.6).
- ✅ Existência de `sps_conta_medica_profissional_proc`, `sps_conta_medica_anexo`, `sps_conta_medica_log`, `sps_autorizacao_guia_anexo` — todas existem, estruturas reais documentadas (§5.5–5.7, §6.3).
- ✅ Valor `'I'` em `sps_protocolo_conta_medica.ie_situacao` — não existe em `dominio_valor`; não usar.
- ✅ Significado do código `8` em `ie_origem_proced` (481) — `TUSS`, lista completa de 17 valores obtida.
- ✅ Valores/rótulos de `ie_classificacao` (112) — 6 valores obtidos (⚠️ divergem do `COMMENT` do DDL, que está desatualizado).
- ✅ Relação direta entre `sps_conta_medica` e `sps_autorizacao_guia` — existe (`idsps_autorizacao_guia` + `idsps_autorizacao_principal`).
- ✅ Tipos de dado reais (`SHOW CREATE TABLE`) das 12 tabelas — extraídos e incorporados nas seções 5–7.

**Ainda pendentes:**
- [ ] Rótulos oficiais do domínio `ie_tabela_tuss` (`18`,`19`,`20`,`22`) — não pesquisado contra `dominio_valor` nesta rodada (não fazia parte do conjunto de nomes buscados); query sugerida: `SELECT * FROM dominio WHERE nm_dominio LIKE '%tabela_tuss%' OR nm_dominio LIKE '%tuss%'`, seguido de `SELECT * FROM dominio_valor WHERE iddominio = <id encontrado>`.
- [ ] `iddominio` de `ie_classif_custo` (`procedimento`) — valores A/M/B confirmados via `COMMENT`, mas nenhum domínio correspondente foi localizado nas buscas por nome desta sessão.
- [ ] Domínio de `sps_conta_medica_anexo.ie_tipo_anexo_conta` — não identificado; candidatos genéricos `542`/`640` não confirmados para esta coluna especificamente (§4.17).
- [ ] Confirmar `iddominio` de `ie_tipo_despesa_tiss` (presente em `procedimento` e `sps_conta_medica_proc`) contra `dominio_valor` — valores 1–9 vistos apenas em `COMMENT` do DDL.
- [ ] Lista completa dos ~120 valores do domínio `513` (`ie_tipo_procedimento`) não foi transcrita neste documento (só uma amostra) — consultar diretamente via `SELECT vl_dominio, ds_dominio_valor FROM dominio_valor WHERE iddominio = 513 ORDER BY nr_seq_apresent` quando necessário.
- [ ] Domínios ainda não pesquisados nesta rodada para os indicadores TISS de `sps_conta_medica`/`sps_autorizacao_guia` (`ie_carater_atendimento_tiss`, `ie_cobertura_especial_tiss`, `ie_indicador_acidente_tiss`, `ie_regime_atendimento_tiss`, `ie_regime_internacao`, `ie_saude_ocupacional_tiss`, `ie_tipo_atendimento_tiss`, `ie_tipo_consulta`, `ie_tipo_internacao_tiss`, `ie_motivo_encerramento_tiss`, `ie_tipo_faturamento_tiss`, `ie_origem_protocolo`, `ie_via_acesso_tiss`, `ie_tipo_tecnica_tiss`) — todas as colunas foram confirmadas como existentes, mas seus domínios de valores não foram extraídos nesta sessão.
- [ ] Investigar o artefato externo referenciado no `COMMENT` de `procedimento.ie_classificacao_interna` ("Decisão Pendente 4, seção 10.3") — não localizado nas fontes desta revisão; pode conter decisões de normalização ainda não aplicadas.
- [ ] Validar se `idsetor_exclusico` (erro de digitação confirmado no nome da coluna real) deve ser corrigido em uma migração futura, e se há código de aplicação já dependente do nome incorreto.

**Nova recomendação de processo**: como ficou demonstrado nesta revisão que o `COMMENT` de coluna do DDL pode ficar **desatualizado** em relação a `dominio_valor` (caso do domínio 112), qualquer nova consulta de domínio deve preferir `dominio_valor` como fonte de verdade, usando o `COMMENT` apenas como pista inicial de contexto.

---

## 10. Fontes consultadas

**Fontes documentais (v1.0, mantidas):**
- `IA/arquitetura.txt`, `IA/db-versionamento-release.md`.
- `IA/Analise de requisitos/Finalizado/SPS - Importacao contratos CE/.claude/skills/user/analise-requisitos/references/padroes_sql.md` (trigger de autorização — validada contra o banco vivo nesta revisão, ver §4.6/§6.1).
- `IA/Analise de requisitos/Contas Pagar e Nota Fiscal/*` (domínio 868/871).
- `IA/Analise de requisitos/Finalizado/SPS - SIB/modelagem.sql`.
- `IA/Demandas/*`, `IA/Dashboards/*`, `IA/Relatorios/*`, `IA/Banco de Dados/CRM_BD_ESTUDOS/*` — ver v1.0 para lista completa; **§4.5 desta revisão invalida o uso de `IA/Dashboards/Operadora e Administadora plano de saude/query_dashboard.sql` como fonte de valores para `sps_conta_medica.ie_situacao`.**
- `docs/ans/documentos/Padrao_TISS_Componente_Conteudo_Estrutura_202511.xlsx` (referência conceitual TISS/ANS — domínio 87 ainda pendente de extração, §4.14).

**Fonte nova desta revisão (v2.0) — banco de dados vivo:**
- Schema `dados`, host `10.0.1.86`, acessado via cliente `mysql` com as credenciais configuradas em `IA/.mcp.json` (servidor MCP `mysql`, pacote `@benborla29/mcp-server-mysql`), em 11/08/2026.
- Comandos executados: `SHOW TABLES LIKE 'sps\_%'`; `SHOW CREATE TABLE` nas 12 tabelas do escopo; `SELECT * FROM dominio WHERE nm_dominio LIKE '%...%'` (buscas por situação, anexo, evento de log, grau de participação); `SELECT * FROM dominio_valor WHERE iddominio IN (...)`; `SELECT identidade, nm_entidade FROM entidade WHERE nm_entidade LIKE '%conta_medica%' OR nm_entidade LIKE '%autorizacao_guia%'`.

⚠️ **Nota de segurança**: o arquivo `IA/.mcp.json` contém credenciais de banco de dados em texto puro (usuário e senha) para um host de rede interna. Recomenda-se ao responsável avaliar se esse arquivo deveria estar sob controle de versão/compartilhamento nesse formato, e considerar mover as credenciais para variáveis de ambiente ou um cofre de segredos.

---

*Fim da documentação.*
