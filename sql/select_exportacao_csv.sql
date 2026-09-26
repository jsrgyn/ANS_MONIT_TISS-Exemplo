-- =============================================================================
-- select_exportacao_csv.sql
--
-- Objetivo
-- --------
-- Extrair, em UM único SELECT, todas as colunas do CSV padrão "guia" exigido
-- pela rotina de geração do .XTE de Monitoramento TISS (schema 01.06.00) deste
-- projeto (ver README.md, docs/LAYOUT_CSV.md e src/domain/monitoramento/).
--
-- Fonte de dados: schema `dados` (Sistema Plataforma da Saúde / pssaude.com.br),
-- entidades de Contas Médicas e Autorização documentadas em
-- docs/modelagem_sys/modelagem.md (v2.0, revisada contra o banco vivo em
-- 11/08/2026) e no relatório "SPS - Custo Médico do usuário por prestador.txt"
-- (docs/modelagem_sys/), que é a referência de negócio para os conceitos de
-- CUSTO AVISADO, CUSTO LIBERADO ("programado para pagamento") e CUSTO PAGO.
--
-- Cada linha do resultado = 1 procedimento de 1 conta médica (sps_conta_medica
-- + sps_conta_medica_proc). Linhas com o mesmo `chave_registro` (a própria
-- conta médica) são agrupadas pela rotina Node em um único registro de XML com
-- procedimentos repetidos — ver `groupRows` em
-- src/infrastructure/csv/parse-monitoring-csv.js.
--
-- Regra de negócio para os 3 estágios de custo (mesmo conceito do relatório
-- "SPS - Custo Médico do usuário por prestador.txt", bandas 5375/5377) — ✅
-- alinhada ao fluxo de envio do Monitoramento TISS: entra no CSV da
-- competência QUALQUER conta médica que teve ao menos UM dos 3 eventos abaixo
-- ocorrido DENTRO do mês de competência informado (não apenas as já pagas):
--   • AVISADO   = sps_protocolo_conta_medica.dt_insert cai na competência
--                 (data de cadastro do PROTOCOLO, não da conta) — ✅ CORRIGIDO
--                 2026-09-21: usa o mesmo evento do relatório-fonte ("CUSTO
--                 AVISADO", bandas 5375/5377) e da query contábil de eventos
--                 (query_diops_dados_eventos_v2.sql, coluna `data_aviso`);
--                 até 2026-09-21 esta query usava indevidamente
--                 sps_conta_medica.dt_insert (data da CONTA), divergindo do
--                 relatório-fonte que ela já afirmava replicar — auditoria
--                 comparando esta query com a exportação contábil de eventos
--                 (10_PROJETOS/exportacao-contabilidade-novamed-integra)
--                 encontrou a divergência e motivou a correção (ver nota 14
--                 no rodapé).
--   • LIBERADO  = primeira mudança de sps_protocolo_conta_medica.ie_situacao
--                 para '2' ("Liberado para pagamento", domínio 871) ocorreu
--                 na competência — rastreada via sps_conta_medica_log, evento
--                 '9' ("Análise Finalizada", domínio 874) — ✅ validado contra
--                 amostra real via MCP MySQL em 2026-08-17 (evento distinto do
--                 evento '4' usado para PAGO; não é a mesma faixa de evento
--                 com valor de domínio diferente, como se supunha antes da
--                 validação).
--   • PAGO      = primeira mudança de ie_situacao para '3' (Pago) ocorreu na
--                 competência — replica literalmente a regra do relatório-fonte
--                 (CTE `eventos_pagamento_ranqueados`).
-- As 3 CTEs de evento (`contas_avisadas_periodo`, `contas_liberadas_periodo`,
-- `contas_pagas_periodo`) são unidas (UNION) em `contas_evento_periodo`; o
-- valor exportado para cada conta (vl_apresentado/vl_liberado/vl_glosado etc.)
-- continua refletindo o estado ATUAL da conta/protocolo — só o critério de
-- ENTRADA no arquivo passou a ser por evento-no-mês, não mais por
-- `ie_situacao` atual + `dt_autorizacao`.
--   • GLOSA     = sps_conta_medica.vl_glosado (independe do estágio de pagamento).
--
-- Legenda de confiança nos comentários desta query (mesma convenção usada em
-- docs/modelagem_sys/modelagem.md):
--   ✅ confirmado no banco vivo (citado literalmente em modelagem.md ou em SQL
--      real de outros projetos do mesmo sistema, ver cabeçalho de cada CTE);
--   🟡 inferido por convenção/analogia com padrões do sistema — validar antes
--      de rodar em produção;
--   🔴 não localizado nas fontes disponíveis nesta sessão (sem acesso MCP ao
--      banco vivo) — usar um valor padrão/param e confirmar com
--      `SHOW CREATE TABLE <tabela>` antes do primeiro uso real.
--
-- Parâmetros (bind) esperados na chamada da aplicação:
--   :idestabelecimento   -- ✅ obrigatório, tenant/estabelecimento logado
--   :competencia         -- ✅ obrigatório, mês de referência do arquivo TISS
--                            no formato AAAAMM (mesmo valor passado ao CLI
--                            `--competencia`, ver README.md); a query deriva
--                            internamente o primeiro e o último dia do mês
--                            (limite final exclusivo) — substitui os antigos
--                            `:dt_inicio`/`:dt_fim` livres, eliminando o risco
--                            de o período do CSV divergir da competência
--                            declarada no nome do arquivo `.XTE`.
--   :idprestador         -- 🟡 opcional; filtra por prestador executante
--                            (passar NULL para todos os prestadores do período)
--   :forma_envio         -- 🔴 default '3' (arquivo original) — Tabela TISS de
--                            forma de envio; ajustar se for retificação ('4')
--   :versao_tiss_prestador -- 🔴 versão do padrão TISS do prestador (campo
--                            opcional no XSD); default '027'. Se o sistema não
--                            rastrear essa informação por prestador, deixar o
--                            parâmetro fixo por operadora.
--   :tipo_registro       -- ✅ '1' inclusão / '2' alteração / '3' exclusão
--                            (default '1' para arquivos de movimento)
--
-- Escopo do bloco TISS: apenas `guia` (BLOCK_TYPES.GUIA). O relatório de
-- origem ("Custo Médico do usuário por prestador") cobre exclusivamente
-- sps_conta_medica (contas médicas executadas/faturadas por prestador), que
-- corresponde 1:1 ao bloco `guia` do Monitoramento TISS — não há dado de
-- origem, neste relatório, para `fornecimento_direto`, `outra_remuneracao` ou
-- `valor_preestabelecido`; por isso um único arquivo .sql resolve a extração
-- (ver docs/LAYOUT_CSV.md).
--
-- Recomendações de performance (MySQL 8):
--   • Garantir índice em sps_protocolo_conta_medica (dt_insert) — filtro
--     primário do evento AVISADO (`contas_avisadas_periodo`, ✅ corrigido
--     2026-09-21 de cm.dt_insert para pcm.dt_insert — ver nota 14 no rodapé);
--   • Garantir índice em sps_conta_medica (idestabelecimento) — usado no
--     filtro de tenant/prestador de `contas_avisadas_periodo`;
--   • Garantir índice em sps_conta_medica_log (idsps_protocolo_conta_medica,
--     ie_autorizacao_evento_log, status, dt_insert) — a query agora varre esta
--     tabela DUAS vezes (uma por ROW_NUMBER() para LIBERADO, outra para PAGO);
--     sem esse índice composto cada varredura degrada para full scan da tabela
--     de log, que tende a crescer indefinidamente;
--   • Garantir índice em sps_conta_medica_proc (idsps_conta_medica) — já é FK,
--     mas confirmar que existe índice (não apenas a constraint);
--   • Garantir índice em sps_protocolo_conta_medica (idsps_protocolo_conta_medica)
--     (PK, já garantido) e em sps_conta_medica (idsps_protocolo_conta_medica);
--   • As CTEs de endereço (`beneficiario_endereco`) usam ROW_NUMBER() para
--     eliminar potenciais duplicidades de complemento/logradouro — evita
--     explosão de linhas (fan-out) antes do JOIN com os procedimentos, que é
--     o produto cartesiano relevante (1 conta × N procedimentos);
--   • `:competencia` sempre delimita exatamente 1 mês (a query nunca varre um
--     intervalo maior que isso) — nunca chamar esta query sem esse parâmetro;
--     sps_conta_medica_proc e sps_conta_medica_log podem ser as maiores
--     tabelas do escopo.
-- =============================================================================
WITH
parametros AS (
    SELECT
        CAST(:idestabelecimento AS UNSIGNED)                AS idestabelecimento,
        CAST(
            CONCAT(LEFT(CAST(:competencia AS CHAR), 4), '-', RIGHT(CAST(:competencia AS CHAR), 2), '-01')
            AS DATE
        )                                                     AS dt_inicio,
        DATE_ADD(
            CAST(
                CONCAT(LEFT(CAST(:competencia AS CHAR), 4), '-', RIGHT(CAST(:competencia AS CHAR), 2), '-01')
                AS DATE
            ),
            INTERVAL 1 MONTH
        )                                                     AS dt_fim_exclusivo,
        NULLIF(CAST(:idprestador AS UNSIGNED), 0)            AS idprestador,
        COALESCE(NULLIF(CAST(:forma_envio AS CHAR), ''), '3')            AS forma_envio,
        COALESCE(NULLIF(CAST(:versao_tiss_prestador AS CHAR), ''), '027') AS versao_tiss_prestador,
        COALESCE(NULLIF(CAST(:tipo_registro AS CHAR), ''), '1')          AS tipo_registro
),
-- -----------------------------------------------------------------------------
-- Evento 1/3 — AVISADO: sps_protocolo_conta_medica.dt_insert (entrada/registro
-- do PROTOCOLO no sistema, não da conta) cai dentro do mês de competência —
-- ✅ CORRIGIDO 2026-09-21 (era cm.dt_insert): mesmo evento usado como "CUSTO
-- AVISADO" no relatório-fonte (CTE `contas_avisadas_pagas`, bandas 5375/5377)
-- e como `data_aviso` na query contábil de exportação de eventos
-- (query_diops_dados_eventos_v2.sql). Exige protocolo ativo, replicando o
-- INNER JOIN do relatório-fonte.
--
-- ✅ AJUSTE 2026-09-23 (nota 35) — achado numa 7ª/8ª análise externa e
-- decisão explícita do usuário ("reclassificar as 15 contas para o mês
-- seguinte"): `sps_protocolo_conta_medica` (o LOTE) às vezes é pré-criado
-- ANTES de a própria conta médica existir — nessas contas, `pcm.dt_insert`
-- (usado sozinho até aqui) cai num mês em que a conta nem existia ainda,
-- fazendo `dataProcessamentoGuia` sair antes de `dataProtocoloCobranca`
-- (campo 032, `cp.dt_cadastro_conta`) e de `dataRealizacao` — sintoma
-- documentado desde a nota 32 (15 guias) e a nota 33 (186 guias) em
-- 04/2026. Levantamento Novamed-wide (2026-09-23) mostrou que NÃO é um caso
-- isolado de 04/2026: é um padrão sistemático recorrente em toda
-- competência já gerada — 184 contas com lote em 04/2026 mas conta
-- cadastrada só em 05/2026, 7 de 05→06, 377 de 06→07, 259 de 07→08 (827
-- contas ao todo). `GREATEST(pcm.dt_insert, cm.dt_insert)` usa SOMENTE
-- datas reais já existentes no próprio registro (nunca fabrica nada): no
-- caso normal (conta cadastrada no mesmo dia do lote ou antes dele,
-- >99% dos casos), o resultado é idêntico a `pcm.dt_insert` (nenhuma
-- mudança de comportamento); só nos casos anômalos (lote pré-criado antes
-- da conta existir) o evento passa a usar `cm.dt_insert` — a data em que o
-- "aviso" de fato PODE ter ocorrido, já que a conta precisa existir antes
-- de poder ser avisada. Efeito colateral esperado e desejado: essas contas
-- deixam de entrar na competência do lote e passam a entrar na competência
-- real (a do cadastro da conta), o que também resolve por completo os
-- achados das notas 32/33 para esse mesmo grupo de contas (a ordem
-- cronológica deixa de ser violada porque `dataProcessamentoGuia` passa a
-- coincidir com `dataProtocoloCobranca`/`dataRealizacao`, todas baseadas na
-- mesma data real de cadastro da conta). Filtro do período (WHERE) também
-- trocado para `GREATEST(...)`, não mais `pcm.dt_insert` sozinho — senão a
-- conta seria selecionada pela janela errada (mês do lote) mas exportada
-- com uma data de evento de outro mês, quebrando a regra 259 ao contrário.
-- Ainda não alinhado de volta com `query_diops_dados_eventos_v2.sql`
-- (`data_aviso`, query contábil) — mesma classe de decisão já registrada em
-- 21/09/2026, fica pendência separada para avaliar se a contábil deveria
-- receber o mesmo ajuste.
-- -----------------------------------------------------------------------------
contas_avisadas_periodo AS (
    SELECT DISTINCT cm.idsps_conta_medica, GREATEST(pcm.dt_insert, cm.dt_insert) AS dt_evento
    FROM sps_conta_medica cm
    INNER JOIN sps_protocolo_conta_medica pcm
            ON pcm.idsps_protocolo_conta_medica = cm.idsps_protocolo_conta_medica
           AND pcm.status = 'A'
    CROSS JOIN parametros p
    WHERE cm.status = 'A'
      AND cm.idestabelecimento = p.idestabelecimento
      AND GREATEST(pcm.dt_insert, cm.dt_insert) >= p.dt_inicio
      AND GREATEST(pcm.dt_insert, cm.dt_insert) <  p.dt_fim_exclusivo
      AND (p.idprestador IS NULL OR cm.idsps_prestador_exec = p.idprestador)
),
-- -----------------------------------------------------------------------------
-- Evento 2/3 — LIBERADO PARA PAGAMENTO: primeira transição de
-- sps_protocolo_conta_medica.ie_situacao para '2' (domínio 871, §4.4,
-- ✅ modelagem.md), rastreada pelo log genérico/polimórfico
-- sps_conta_medica_log. ✅ VALIDADO via MCP MySQL contra o banco vivo
-- (2026-08-17): ao contrário do evento PAGO (que usa
-- ie_autorizacao_evento_log = '4'), a transição para LIBERADO é registrada sob
-- o evento '9' ("Análise Finalizada", domínio 874 §4.8b) — `vl_novo` real
-- observado: `[{"chave":"vl_glosado",...},{"chave":"ie_situacao","valor":"2"},
-- {"chave":"vl_liberado",...},...,{"chave":"dt_liberacao_protocolo",...}]`.
-- `vl_novo` é um ARRAY de objetos (não um objeto único) — JSON_CONTAINS com
-- JSON_OBJECT casa corretamente contra elementos do array, mecanismo confirmado
-- funcional na amostra real.
-- -----------------------------------------------------------------------------
eventos_liberacao_ranqueados AS (
    SELECT
        cl.idsps_protocolo_conta_medica,
        cl.dt_insert AS dt_liberacao,
        ROW_NUMBER() OVER (
            PARTITION BY cl.idsps_protocolo_conta_medica
            ORDER BY cl.dt_insert, cl.idsps_conta_medica_log
        ) AS nr_evento_liberacao
    FROM sps_conta_medica_log cl
    WHERE cl.status = 'A'
      AND cl.idsps_protocolo_conta_medica IS NOT NULL
      AND cl.ie_autorizacao_evento_log = '9'
      AND JSON_VALID(cl.vl_novo)
      AND JSON_CONTAINS(
            cl.vl_novo,
            JSON_OBJECT('chave', 'ie_situacao', 'valor', '2')
      )
),
protocolos_liberados_periodo AS (
    SELECT elr.idsps_protocolo_conta_medica, elr.dt_liberacao AS dt_evento
    FROM eventos_liberacao_ranqueados elr
    CROSS JOIN parametros p
    WHERE elr.nr_evento_liberacao = 1
      AND elr.dt_liberacao >= p.dt_inicio
      AND elr.dt_liberacao <  p.dt_fim_exclusivo
),
contas_liberadas_periodo AS (
    SELECT DISTINCT cm.idsps_conta_medica, plp.dt_evento
    FROM sps_conta_medica cm
    INNER JOIN protocolos_liberados_periodo plp
            ON plp.idsps_protocolo_conta_medica = cm.idsps_protocolo_conta_medica
    CROSS JOIN parametros p
    WHERE cm.status = 'A'
      AND cm.idestabelecimento = p.idestabelecimento
      AND (p.idprestador IS NULL OR cm.idsps_prestador_exec = p.idprestador)
),
-- -----------------------------------------------------------------------------
-- Evento 3/3 — PAGO: primeira transição de ie_situacao para '3' (Pago) —
-- ✅ replica literalmente a CTE `eventos_pagamento_ranqueados` do
-- relatório-fonte (mesmo evento '4', mesmo padrão de JSON_CONTAINS).
-- -----------------------------------------------------------------------------
eventos_pagamento_ranqueados AS (
    SELECT
        cl.idsps_protocolo_conta_medica,
        cl.dt_insert AS dt_pagamento,
        ROW_NUMBER() OVER (
            PARTITION BY cl.idsps_protocolo_conta_medica
            ORDER BY cl.dt_insert, cl.idsps_conta_medica_log
        ) AS nr_evento_pagamento
    FROM sps_conta_medica_log cl
    WHERE cl.status = 'A'
      AND cl.idsps_protocolo_conta_medica IS NOT NULL
      AND cl.ie_autorizacao_evento_log = '4'
      AND JSON_VALID(cl.vl_novo)
      AND JSON_CONTAINS(
            cl.vl_novo,
            JSON_OBJECT('chave', 'ie_situacao', 'valor', '3')
      )
),
protocolos_pagos_periodo AS (
    SELECT epr.idsps_protocolo_conta_medica, epr.dt_pagamento AS dt_evento
    FROM eventos_pagamento_ranqueados epr
    CROSS JOIN parametros p
    WHERE epr.nr_evento_pagamento = 1
      AND epr.dt_pagamento >= p.dt_inicio
      AND epr.dt_pagamento <  p.dt_fim_exclusivo
),
contas_pagas_periodo AS (
    SELECT DISTINCT cm.idsps_conta_medica, ppp.dt_evento
    FROM sps_conta_medica cm
    INNER JOIN protocolos_pagos_periodo ppp
            ON ppp.idsps_protocolo_conta_medica = cm.idsps_protocolo_conta_medica
    CROSS JOIN parametros p
    WHERE cm.status = 'A'
      AND cm.idestabelecimento = p.idestabelecimento
      AND (p.idprestador IS NULL OR cm.idsps_prestador_exec = p.idprestador)
),
-- -----------------------------------------------------------------------------
-- ✅ REDESENHADO 2026-09-22 — achado crítico: a ANS rejeita o arquivo quando
-- `dataProcessamentoGuia` de um lançamento de Inclusão não bate com o mês/ano
-- da competência do arquivo (Padrão TISS - Componente Organizacional, julho
-- 2026, regra 259: "Em cada arquivo enviado todos os lançamentos com tipo de
-- registro igual a 'inclusão' devem ter o mês/ano da data de processamento
-- igual ao mês/ano da competência do arquivo. Caso contrário, o arquivo será
-- rejeitado."). Os Quadros 6-8 (regra 290, mesmo documento) mostram o modelo
-- real: a MESMA guia gera um lançamento de Inclusão NOVO em CADA competência
-- em que sofreu processamento (aviso, liberação, pagamento), cada um com sua
-- própria `dataProcessamentoGuia` e os valores vigentes NAQUELE momento — não
-- é "1 linha por conta com o estado atual". Confirmado no arquivo real
-- gerado para 04/2026: 272 das 279 contas (avisadas em abril, liberadas só
-- em maio) saíram com `dataProcessamentoGuia` de MAIO dentro do arquivo de
-- ABRIL (usando o antigo COALESCE de datas "atuais"), violando a regra 259.
--
-- Correção: em vez de UNIÃO simples de IDs de conta, cada CTE de evento
-- (avisado/liberado/pago) agora carrega sua própria `dt_evento`. Quando uma
-- conta qualifica por mais de 1 evento NA MESMA competência (ex.: avisada e
-- liberada no mesmo mês), escolhe-se o evento de maior "prioridade"
-- (PAGO > LIBERADO > AVISADO) como o lançamento desta competência — decisão
-- do usuário 2026-09-22 (alternativa seria 2 lançamentos separados, mais
-- fiel ao modelo ANS porém mais complexa; não implementada). O evento
-- escolhido define `dataProcessamentoGuia` E controla quais valores aparecem
-- "zerados" (conta ainda não processada/paga NAQUELE momento) — ver CASE nas
-- colunas valor_processado/valor_glosa_guia/valor_pago_guia/tg.*/
-- data_pagamento/item valor_pago_procedimento/quantidade_paga no SELECT
-- final, todos agora condicionados a `cp.tipo_evento_lancamento` em vez do
-- estado ATUAL (`ps.protocolo_pago`) — decisão do usuário 2026-09-22:
-- lançamento AVISADO mostra só valorInformado (liberado/pago = 0), mesmo que
-- a conta já tenha avançado de estágio depois (esse avanço pertence ao
-- lançamento da competência em que ocorreu, não a este).
-- -----------------------------------------------------------------------------
eventos_candidatos_periodo AS (
    SELECT idsps_conta_medica, 'AVISADO'  AS tipo_evento, dt_evento, 1 AS prioridade FROM contas_avisadas_periodo
    UNION ALL
    SELECT idsps_conta_medica, 'LIBERADO', dt_evento, 2 AS prioridade FROM contas_liberadas_periodo
    UNION ALL
    SELECT idsps_conta_medica, 'PAGO',     dt_evento, 3 AS prioridade FROM contas_pagas_periodo
),
contas_evento_periodo AS (
    SELECT idsps_conta_medica, tipo_evento, dt_evento
    FROM (
        SELECT
            idsps_conta_medica, tipo_evento, dt_evento,
            ROW_NUMBER() OVER (PARTITION BY idsps_conta_medica ORDER BY prioridade DESC) AS rn
        FROM eventos_candidatos_periodo
    ) ranqueado
    WHERE rn = 1
),
-- -----------------------------------------------------------------------------
-- Contas médicas selecionadas pelo evento vencedor de cada uma (ver CTE
-- acima). `vl_apresentado` é o único valor de cabeçalho que reflete o estado
-- ATUAL sem ressalva (o "valor informado" não muda depois de registrado);
-- `vl_liberado`/`vl_glosado` também vêm no estado atual, mas só são
-- efetivamente usados no SELECT final quando `tipo_evento_lancamento`
-- justifica (LIBERADO/PAGO) — ver CASE nas colunas correspondentes.
-- -----------------------------------------------------------------------------
contas_periodo AS (
    SELECT
        cm.idsps_conta_medica,                 -- ✅ PK (modelagem.md §5.3)
        cm.idsps_protocolo_conta_medica,        -- ✅
        cm.idsps_beneficiario,                  -- ✅
        cm.idsps_prestador_exec,                -- ✅
        cm.idsps_autorizacao_guia,              -- ✅
        cm.nr_guia_prestador,                   -- ✅ confirmado em uso real
                                                 --    (relatorio_sps_demonstrativo_coparticipacao_novamed.txt)
                                                 -- (nr_guia_operadora NÃO existe — ✅ confirmado via
                                                 --  SHOW CREATE TABLE em sps_conta_medica E em
                                                 --  sps_autorizacao_guia; nenhuma das duas tabelas tem
                                                 --  coluna própria para "número da guia na operadora")
        cm.dt_autorizacao,                      -- ✅
        cm.dt_inicio_faturamento,               -- ✅
        cm.dt_fim_faturamento,                  -- ✅
        cm.dt_inicio_analise,                   -- ✅
        cm.dt_fim_analise,                      -- ✅
        cm.dt_pagamento,                        -- ✅
        cm.dt_alta,                             -- ✅
        cm.dt_insert                AS dt_cadastro_conta, -- ✅ NOT NULL (modelagem.md) — usado só como
                                                 --    último fallback não-nulo de `data_realizacao`
        cm.cd_cbo,                              -- ✅ profissional executante denormalizado
        cm.nm_profissional,                     -- ✅
        cm.nr_conselho,                         -- ✅
        cm.sg_conselho,                         -- ✅
        cm.uf_conselho,                         -- ✅
        cm.ie_tipo_consulta,                    -- ✅ coluna existe; domínio 🔴 não extraído
        cm.ie_atendimento_rn,                   -- ✅ coluna existe; domínio 🔴
        cm.ie_indicador_acidente_tiss,          -- ✅ coluna existe; domínio 🔴
        cm.ie_carater_atendimento_tiss,         -- ✅ coluna existe; domínio 🔴
        cm.ie_tipo_internacao_tiss,             -- ✅ coluna existe; domínio 🔴
        cm.ie_regime_internacao,                -- ✅ coluna existe; domínio 🔴
        cm.ie_tipo_atendimento_tiss,             -- ✅ coluna existe; domínio 🔴
        cm.ie_regime_atendimento_tiss,           -- ✅ coluna existe; domínio 🔴
        cm.ie_saude_ocupacional_tiss,            -- ✅ coluna existe; domínio 🔴
        cm.ie_tipo_faturamento_tiss,             -- ✅ coluna existe; domínio 🔴
        cm.ie_motivo_encerramento_tiss,          -- ✅ coluna existe; domínio 🔴
        cm.ie_tipo_guia_tiss,                    -- ✅ coluna existe; domínio 🔴
        cm.ie_origem_conta,                      -- ✅ coluna existe; domínio 🔴
        cm.cd_cid_doenca_princ,                  -- ✅
        cm.cd_cid_doenca_seg,                    -- ✅
        cm.cd_cid_doenca_terc,                   -- ✅
        cm.cd_cid_doenca_quar,                   -- ✅
        cm.nr_declaracao_nascido_vivo,           -- ✅
        cm.nr_declaracao_obito,                  -- ✅
        cm.vl_apresentado,                       -- ✅ = CUSTO AVISADO
        cm.vl_liberado,                          -- ✅ = CUSTO LIBERADO / "programado p/ pagamento"
        cm.vl_glosado,                           -- ✅ = CUSTO GLOSA
        cm.vl_coparticipacao,                    -- ✅
        cep.tipo_evento AS tipo_evento_lancamento, -- ✅ AVISADO/LIBERADO/PAGO — evento vencedor desta competência
        cep.dt_evento    AS dt_evento_lancamento   -- ✅ data própria do evento vencedor (vira dataProcessamentoGuia)
    -- ✅ AJUSTE 2026-09-25 (nota 42) — pedido explícito do usuário: excluir da
    -- exportação qualquer conta médica cujo beneficiário ou o contrato do
    -- beneficiário seja administrado por uma administradora de benefícios
    -- (`ie_ADM='S'`, não relacionado ao domínio 11). Só entram no arquivo
    -- contas cujo `sps_beneficiario.ie_ADM` e `sps_contrato.ie_ADM` (via
    -- `sb.idsps_contrato`) sejam NULL ou 'N'. INNER JOIN seguro: as duas FKs
    -- (`idsps_beneficiario`, `idsps_contrato`) são NOT NULL no schema.
    -- ✅ AJUSTE 2026-09-25 (nota 44) — achado do setor de contas Novamed: a conta
    -- 3580 (07/2026) saiu no CSV com o LOTE (`sps_lote_conta_medica`, id 113,
    -- "Dr. Fabricio Tiago Martins Arruda - Anestesista") já **inativo**
    -- (`status='I'`), embora a própria conta e o protocolo continuassem `status='A'`
    -- — `sps_conta_medica`/`sps_protocolo_conta_medica` já eram filtrados por
    -- status desde a criação da query, mas `sps_lote_conta_medica` nunca tinha sido
    -- referenciado. Levantamento Novamed-wide (`idestabelecimento=19`) achou mais 4
    -- lotes inativos nas mesmas condições — 12 ("Consultas eletivas Dr. Romulo
    -- Orlando", 1 conta, já presente no `.XTE` TRANSMITIDO de 05/2026, achado
    -- separado registrado em PENDENCIAS-CONFIRMACAO.md), 70 e 71 (1 conta cada), e
    -- **90 ("Consultas - Rafael", 76 contas, o maior grupo)** — todas as 79
    -- restantes (exceto a 380/lote 12, já em 05/2026) caem na população de
    -- 07/2026, ainda não transmitida. `idsps_lote_conta_medica` é nulável em
    -- `sps_protocolo_conta_medica` (protocolo pode existir sem lote atribuído
    -- ainda, ver modelagem.md) — por isso o `LEFT JOIN` com `OR ... IS NULL`, não
    -- um `INNER JOIN` que excluiria indevidamente todo protocolo sem lote.
    FROM sps_conta_medica cm
    INNER JOIN contas_evento_periodo cep
            ON cep.idsps_conta_medica = cm.idsps_conta_medica
    INNER JOIN sps_protocolo_conta_medica pcm
            ON pcm.idsps_protocolo_conta_medica = cm.idsps_protocolo_conta_medica
           AND pcm.status = 'A'
    INNER JOIN sps_beneficiario sb_adm ON sb_adm.idsps_beneficiario = cm.idsps_beneficiario -- ✅ nota 42
    INNER JOIN sps_contrato sc_adm ON sc_adm.idsps_contrato = sb_adm.idsps_contrato         -- ✅ nota 42
    LEFT JOIN sps_lote_conta_medica lcm ON lcm.idsps_lote_conta_medica = pcm.idsps_lote_conta_medica -- ✅ nota 44
    CROSS JOIN parametros p
    WHERE cm.status = 'A'
      AND cm.idestabelecimento = p.idestabelecimento
      AND (sb_adm.ie_ADM IS NULL OR sb_adm.ie_ADM = 'N')                                    -- ✅ nota 42
      AND (sc_adm.ie_ADM IS NULL OR sc_adm.ie_ADM = 'N')                                    -- ✅ nota 42
      AND (pcm.idsps_lote_conta_medica IS NULL OR lcm.status = 'A')                         -- ✅ nota 44
),
-- -----------------------------------------------------------------------------
-- Situação do protocolo (para aplicar a regra do CUSTO PAGO) e a data de
-- recebimento do protocolo pela operadora, usada como `data_protocolo_cobranca`
-- (sps_protocolo_conta_medica.dt_recebimento — ✅ confirmado em modelagem.md §5.2).
-- -----------------------------------------------------------------------------
protocolo_situacao AS (
    SELECT
        pcm.idsps_protocolo_conta_medica,
        pcm.ie_situacao,                          -- ✅ domínio 871 (§4.4)
        (pcm.ie_situacao = '3')                   AS protocolo_pago,   -- ✅ '3' = Pago
        pcm.dt_recebimento,                       -- ✅
        pcm.dt_liberacao_protocolo,                -- ✅
        pcm.dt_pagamento_protocolo,                -- ✅
        pcm.dt_insert                AS dt_cadastro_protocolo -- ✅ NOT NULL (confirmado via MCP MySQL,
                                                   --    2026-08-19) — `dt_recebimento` está SEMPRE NULL
                                                   --    na base viva (nunca gravado pela aplicação); esta
                                                   --    coluna é o fallback não-nulo mais próximo
                                                   --    semanticamente (data de cadastro do protocolo)
    FROM sps_protocolo_conta_medica pcm
),
-- -----------------------------------------------------------------------------
-- Endereço residencial do beneficiário, para obter o código IBGE do município
-- (padrão já usado em produção para o SIB: pessoa_fisica_compl → logradouro →
-- municipio, filtrando ie_tipo_complemento = 1 = endereço residencial).
-- ROW_NUMBER() evita duplicar a conta médica caso exista mais de um endereço
-- do mesmo tipo cadastrado (mantém o mais recente).
-- -----------------------------------------------------------------------------
beneficiario_endereco AS (
    SELECT
        pfc.idpessoa_fisica,
        m.cd_ibge,
        ROW_NUMBER() OVER (
            PARTITION BY pfc.idpessoa_fisica
            ORDER BY pfc.dt_update DESC, pfc.idpessoa_fisica_compl DESC
        ) AS nr_ordem
    FROM pessoa_fisica_compl pfc              -- ✅ tabela e colunas usadas em produção (SIB)
    LEFT JOIN logradouro l ON l.cep = pfc.cep AND l.status = 'A' -- ✅ nota 37
    LEFT JOIN municipio m ON m.idmunicipio = l.idmunicipio AND m.status = 'A' -- ✅ nota 37
    WHERE pfc.ie_tipo_complemento = 1         -- ✅ 1 = endereço residencial (padrão SIB)
      AND pfc.status = 'A'                    -- ✅ nota 37 — só endereço ativo
),
-- -----------------------------------------------------------------------------
-- Dados do beneficiário: CNS/CPF/sexo/nascimento (pessoa_fisica — ✅ confirmado
-- em produção), produto/plano contratado (sps_produto.nr_protocolo_ans — ✅
-- confirmado como o número de registro do produto na ANS, mesmo campo usado
-- na geração do SIB) e município de residência (via beneficiario_endereco).
--
-- ✅ AJUSTE 2026-09-24 (nota 37) — achado a pedido do usuário: `sps_beneficiario`,
-- `pessoa_fisica` e `sps_produto` não tinham filtro de `status`, ao contrário de
-- `sps_conta_medica`/`sps_protocolo_conta_medica`/`sps_conta_medica_log`/
-- `sps_conta_medica_proc` (já filtrados desde a criação da query). Confirmado em
-- produção (idestabelecimento=19): 2 contas médicas reais (2038, já exportada em
-- 06/2026; 4741, já exportada em 07/2026) pertencem ao beneficiário ativo 3352
-- cujo `pessoa_fisica` vinculado está `status='I'` — dado de identidade inativo
-- sendo declarado à ANS como se fosse válido. `pf.status='A'` movido para dentro
-- do INNER JOIN (não um WHERE solto): quando o vínculo pessoa_fisica é inativo, o
-- beneficiário inteiro deixa de casar nesta CTE — a conta médica correspondente
-- continua na exportação (mesma regra de inclusão de sempre, por evento), mas com
-- os campos de beneficiário em branco, exatamente como já acontece hoje para
-- lacunas de cadastro (endereço/CNS ausente) — passa a ser capturado pela mesma
-- auditoria de "Sem CPF/CNS/dados de beneficiário" em CORRECOES-NECESSARIAS.md,
-- não fabricado nem inventado. Mesmo raciocínio aplicado a `sb.status='A'` (WHERE
-- da própria CTE) e `sp.status='A'` (LEFT JOIN de sps_produto) — sem efeito
-- observado hoje (0 contas com sps_beneficiario/sps_produto inativo em
-- idestabelecimento=19), mas mantém a regra simétrica para qualquer entidade
-- referenciada na query.
-- -----------------------------------------------------------------------------
beneficiario_dados AS (
    SELECT
        sb.idsps_beneficiario,
        pf.nr_cpf,                                              -- ✅
        pf.nr_cartao_nac_sus,                                   -- ✅
        pf.dt_nascimento,                                       -- ✅
        CASE WHEN pf.ie_sexo = 'M' THEN '1' ELSE '3' END AS sexo_tiss, -- ✅ mesma
                                                                 -- convenção usada na
                                                                 -- geração do SIB (Tabela TISS de sexo)
        sp.nr_protocolo_ans                        AS plano_registro, -- ✅
        LEFT(be.cd_ibge, 6)                         AS municipio_ibge -- ✅ (via beneficiario_endereco)
    FROM sps_beneficiario sb
    INNER JOIN pessoa_fisica pf ON pf.idpessoa_fisica = sb.idpessoa_fisica
                                AND pf.status = 'A'                                -- ✅ nota 37
    LEFT JOIN sps_produto sp ON sp.idsps_produto = sb.idsps_produto
                             AND sp.status = 'A'                                   -- ✅ nota 37
    LEFT JOIN beneficiario_endereco be
           ON be.idpessoa_fisica = sb.idpessoa_fisica AND be.nr_ordem = 1
    WHERE sb.status = 'A'                                                          -- ✅ nota 37
),
-- -----------------------------------------------------------------------------
-- Endereço do prestador (PJ e PF), para obter o código IBGE do município via
-- CEP — mesmo mecanismo já usado em `beneficiario_endereco` (CEP → logradouro
-- → municipio). ✅ VALIDADO via MCP MySQL (2026-08-17): nem `pessoa_juridica`
-- nem `pessoa_fisica` têm coluna própria de código IBGE (a suposição anterior
-- `cd_municipio_ibge` não existe em nenhuma das duas); `pessoa_juridica.cep`
-- e `pessoa_fisica_compl.cep` (mesma tabela/filtro usados para o beneficiário)
-- resolvem corretamente contra `logradouro`/`municipio` em amostra real.
-- -----------------------------------------------------------------------------
-- ✅ AJUSTE 2026-09-24 (nota 37) — `l.status`/`m.status` filtrados nos dois
-- CTEs abaixo (endereço de prestador PJ e PF), mesma regra aplicada a
-- `beneficiario_endereco`: endereço/município inativo não deve alimentar o
-- código IBGE exportado.
prestador_endereco_pj AS (
    SELECT
        pj.idpessoa_juridica,
        m.cd_ibge
    FROM pessoa_juridica pj
    LEFT JOIN logradouro l ON l.cep = pj.cep AND l.status = 'A'          -- ✅ nota 37
    LEFT JOIN municipio m ON m.idmunicipio = l.idmunicipio AND m.status = 'A' -- ✅ nota 37
),
-- ✅ AJUSTE 2026-09-24 (nota 41) — pedido explícito do usuário: priorizar o
-- endereço marcado como principal (`ie_principal='S'`) em vez de só o tipo
-- Residencial (`ie_tipo_complemento=1`) mais recente. Achado ao investigar
-- antes de corrigir: 2 prestadores PF da Novamed (Daniel Portilho De Melo,
-- Paulo Estefano Germano) tiveram o cadastro de endereço corrigido em
-- produção em 24/09/2026, mas só como tipo Comercial (2, `ie_principal='S'`)
-- — a restrição antiga a tipo=1 continuava deixando os dois sem endereço
-- resolvível mesmo já corrigidos (domínio 71 confirmado via `dominio_valor`:
-- 1=Residencial, 2=Comercial). Verificado Novamed-wide (idestabelecimento=19,
-- todos os prestadores PF ativos) antes de trocar: dos 15 prestadores PF, a
-- troca resolveria os 2 citados mas quebraria 1 (Julio Eduardo Ferro,
-- idsps_prestador 67, sem movimento em nenhuma competência já gerada
-- 04-07/2026) — seu endereço marcado como principal (tipo Comercial) não tem
-- CEP cadastrado, só o tipo Residencial (não-principal) tem. Implementado com
-- fallback, sem fabricar nenhum dado: prioriza `ie_principal='S'`, mas só
-- entre os complementos que de fato resolvem a um município real
-- (`cd_ibge IS NOT NULL`); quando o principal não resolve, cai para o
-- complemento ativo mais recente que resolver, de qualquer tipo — mesmo
-- critério já usado no restante da query (nunca inventar endereço).
prestador_endereco_pf AS (
    SELECT
        idpessoa_fisica,
        cd_ibge,
        ROW_NUMBER() OVER (
            PARTITION BY idpessoa_fisica
            ORDER BY ie_principal_flag DESC, dt_update DESC, idpessoa_fisica_compl DESC
        ) AS nr_ordem
    FROM (
        SELECT
            pfc.idpessoa_fisica,
            pfc.dt_update,
            pfc.idpessoa_fisica_compl,
            CASE WHEN pfc.ie_principal = 'S' THEN 1 ELSE 0 END AS ie_principal_flag,
            m.cd_ibge
        FROM pessoa_fisica_compl pfc
        LEFT JOIN logradouro l ON l.cep = pfc.cep AND l.status = 'A'          -- ✅ nota 37
        LEFT JOIN municipio m ON m.idmunicipio = l.idmunicipio AND m.status = 'A' -- ✅ nota 37
        WHERE pfc.status = 'A'                                                -- ✅ nota 37
    ) resolvidos
    WHERE cd_ibge IS NOT NULL
),
-- -----------------------------------------------------------------------------
-- Dados do prestador executante: CNES/CNPJ (pessoa_juridica — ✅ cd_cnes e cnpj
-- confirmados em padroes_sql.md "Help de prestador"). Prestador Pessoa Física
-- (profissional autônomo, identificador TISS '2' = CPF) é tratado via
-- sps_prestador.idpessoa_fisica — ✅ CONFIRMADO via MCP MySQL (2026-08-17):
-- a coluna existe de fato (`sps_prestador.idpessoa_fisica bigint`, FK →
-- pessoa_fisica), a suposição da sessão anterior estava correta.
-- -----------------------------------------------------------------------------
prestador_dados AS (
    SELECT
        sp.idsps_prestador,
        CASE WHEN pj.idpessoa_juridica IS NOT NULL THEN '1' ELSE '2' END AS tipo_identificacao_tiss,
        COALESCE(
            REGEXP_REPLACE(pj.cnpj, '[^A-Za-z0-9]', ''),
            REGEXP_REPLACE(pf.nr_cpf, '[^0-9]', '')
        )                                                        AS cpf_cnpj,
        pj.cd_cnes                                                AS cnes,        -- ✅ (padroes_sql.md)
        COALESCE(pej.cd_ibge, pef.cd_ibge)                        AS municipio_ibge, -- ✅ via CEP (ver acima)
        -- ✅ AJUSTE 2026-09-22 — origem_evento_atencao: `sps_prestador.
        -- ie_tipo_relacao_prestador` (domínio 843) é o campo correto (confirmado
        -- pelo usuário), não `sps_conta_medica.ie_origem_conta` (domínio 869,
        -- que descreve MÉTODO DE DIGITAÇÃO da conta — Manual/Sistema/XML —,
        -- sem relação nenhuma com rede de prestador; usá-lo seria corrigir o
        -- campo errado). Mesmo campo já usado com o mesmo propósito na query
        -- contábil de eventos (query_diops_dados_eventos_v2.sql, coluna
        -- "rede"). Mapeamento para o domínio ANS 1-5 confirmado pelo usuário
        -- 2026-09-22, só para os 3 valores presentes na base viva de
        -- idestabelecimento=19 (843=1/4/6, 100% dos prestadores do escopo);
        -- 843=2/3/5 não ocorrem hoje e ficam propositalmente NULL (gera erro
        -- visível de XSD se aparecerem, em vez de assumir um valor não
        -- confirmado):
        --   843=1 Contratualização Direta (Credenciamento) → ANS 1 (Rede
        --         Contratada/referenciada/credenciada)
        --   843=6 Rede Própria                              → ANS 3 (Rede
        --         Própria-Demais prestadores)
        --   843=4 Não Contratualizado                       → ANS 5
        --         (Prestador eventual)
        CASE sp.ie_tipo_relacao_prestador
            WHEN '1' THEN '1'
            WHEN '6' THEN '3'
            WHEN '4' THEN '5'
            ELSE NULL
        END                                                        AS origem_evento_atencao_ans
    -- ✅ AJUSTE 2026-09-24 (nota 37) — `sps_prestador`/`pessoa_juridica`/
    -- `pessoa_fisica` não tinham filtro de `status` (mesmo achado da nota 37 em
    -- `beneficiario_dados`); 0 contas de idestabelecimento=19 afetadas hoje, mas
    -- filtro adicionado por simetria/prevenção — ver nota 37 no rodapé.
    FROM sps_prestador sp
    LEFT JOIN pessoa_juridica pj ON pj.idpessoa_juridica = sp.idpessoa_juridica AND pj.status = 'A' -- ✅ nota 37
    LEFT JOIN pessoa_fisica  pf ON pf.idpessoa_fisica  = sp.idpessoa_fisica     AND pf.status = 'A' -- ✅ nota 37
    LEFT JOIN prestador_endereco_pj pej ON pej.idpessoa_juridica = pj.idpessoa_juridica
    LEFT JOIN prestador_endereco_pf pef ON pef.idpessoa_fisica = pf.idpessoa_fisica AND pef.nr_ordem = 1
    WHERE sp.status = 'A'                                                                           -- ✅ nota 37
),
-- -----------------------------------------------------------------------------
-- Totais por classificação de despesa (procedimento.ie_classificacao, domínio
-- 112, ✅ confirmado em modelagem.md §4.11: 1 Procedimentos, 2 Serviços
-- Hospitalares, 3 Diárias, 4 Materiais e OPME, 5 Medicamentos, 6 Gases).
-- O XSD do Monitoramento separa Materiais de OPME; como o domínio 112 os
-- mantém juntos (código 4), o split usa procedimento.ie_tabela_tuss = '19'
-- (Tabela TISS 19 = Órteses/Próteses/Materiais Especiais = OPME) — 🟡 regra de
-- negócio inferida a partir da nomenclatura oficial das tabelas TISS, validar
-- com a área de faturamento. "Gases Medicinais" (6) é somado a Taxas, pois o
-- XSD de Monitoramento não possui total próprio para gases.
-- ✅ AJUSTE 2026-09-25 (nota 43) — achado numa 14ª análise externa (06/2026):
-- `ie_classificacao IS NULL` para 2 códigos, únicos na base Novamed inteira
-- (idprocedimento 34107 "kit EPI UTI", 34108 "Material Hospitalar") — como
-- nenhum WHEN abaixo cobre NULL, o valor pago desses itens não entrava em
-- NENHUM dos 6 buckets de categoria, mas continuava no total item a item
-- (`valor_pago_procedimento`, fonte de `valorPagoGuia`, sem filtro de
-- classificação) — violava a regra ANS "valorPagoGuia = soma das 6
-- categorias" em toda guia com item de um desses 2 códigos e valor pago > 0
-- (23 guias em 06/2026). Decisão de Johnathan (pergunta explícita, mesmo
-- critério das notas 30/40): mapear os 2 códigos para categoria 4 (Materiais
-- e OPME) só nesta query — os próprios nomes dos procedimentos confirmam a
-- categoria, sem tocar produção. `COALESCE` aplicado nos 6 buckets.
-- -----------------------------------------------------------------------------
totais_guia AS (
    SELECT
        scmp.idsps_conta_medica,
        SUM(CASE WHEN COALESCE(p.ie_classificacao, CASE WHEN p.idprocedimento IN (34107, 34108) THEN '4' END) = '1'
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_pago_procedimentos,
        SUM(CASE WHEN COALESCE(p.ie_classificacao, CASE WHEN p.idprocedimento IN (34107, 34108) THEN '4' END) = '3'
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_diarias,
        SUM(CASE WHEN COALESCE(p.ie_classificacao, CASE WHEN p.idprocedimento IN (34107, 34108) THEN '4' END) IN ('2', '6')
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_taxas,
        SUM(CASE WHEN COALESCE(p.ie_classificacao, CASE WHEN p.idprocedimento IN (34107, 34108) THEN '4' END) = '4' AND p.ie_tabela_tuss <> '19'
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_materiais,
        SUM(CASE WHEN COALESCE(p.ie_classificacao, CASE WHEN p.idprocedimento IN (34107, 34108) THEN '4' END) = '4' AND p.ie_tabela_tuss = '19'
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_opme,
        SUM(CASE WHEN COALESCE(p.ie_classificacao, CASE WHEN p.idprocedimento IN (34107, 34108) THEN '4' END) = '5'
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_medicamentos,
        -- ✅ AJUSTE 2026-09-23 (nota 29) — soma real do campo 085 (valor de
        -- coparticipação por item) por conta, não gated por lançamento
        -- (coparticipação é valor informado, igual em todos os lançamentos
        -- da guia — mesmo princípio já aplicado ao campo 050/071). Usada
        -- para corrigir `valor_total_coparticipacao` (campo 084 exige que
        -- seja igual à soma dos itens do mesmo lançamento).
        SUM(COALESCE(scmp.vl_coparticipacao, 0))                                  AS vl_coparticipacao_total
    FROM sps_conta_medica_proc scmp
    INNER JOIN procedimento p ON p.idprocedimento = scmp.idprocedimento
                              AND p.status = 'A'                     -- ✅ nota 37
    WHERE scmp.status = 'A'
    GROUP BY scmp.idsps_conta_medica
),
-- -----------------------------------------------------------------------------
-- ✅ AJUSTE 2026-09-22 — achado ao auditar o XML real gerado com registro ANS
-- verdadeiro (não aparece na validação XSD estrutural, só analisando o
-- significado dos campos): `data_realizacao` usava `cm.dt_insert` (data de
-- CADASTRO da conta) como último fallback, quando na verdade
-- `sps_conta_medica_proc.dt_realizacao` (data real de execução, por item) já
-- existe e está preenchida em 99,6% das contas da Novamed (7.171/7.199,
-- confirmado via MCP MySQL). Usar o cadastro como proxy de "realização"
-- inflava a data pra bem depois do atendimento real (exemplo real: conta 18,
-- cadastro em 28/04, realização real em 20/03) — o que fazia
-- `dataProtocoloCobranca`/`dataProcessamentoGuia` (corretas) parecerem
-- anteriores à "realização" (errada), violando a regra ANS de que o
-- protocolo de cobrança não pode ser anterior à realização. `MIN(dt_realizacao)`
-- por conta é a data de realização real do primeiro item; mantém o fallback
-- antigo só para os ~0,4% de contas sem nenhum item com data.
-- -----------------------------------------------------------------------------
realizacao_conta AS (
    SELECT idsps_conta_medica, MIN(dt_realizacao) AS dt_realizacao_real
    FROM sps_conta_medica_proc
    WHERE status = 'A' AND dt_realizacao IS NOT NULL
    GROUP BY idsps_conta_medica
),
-- -----------------------------------------------------------------------------
-- Itens (procedimentos) da conta médica.
-- ✅ AJUSTE 2026-09-23 (nota 31) — achado em auditorias sucessivas (04/2026:
-- contas 131/142; padrão recorrente e crescente em 05-07/2026, ver
-- CORRECOES-NECESSARIAS.md de cada competência): a mesma guia às vezes tem o
-- MESMO procedimento (mesma `ie_tabela_tuss`+`cd_procedimento`) lançado em
-- múltiplas linhas de `sps_conta_medica_proc` (PKs distintas, ambas
-- `status='A'`, valores frequentemente diferentes entre si — ex. conta 131,
-- procedimento 40302580: uma linha R$3,48, outra R$16,55). O Padrão TISS
-- proíbe repetição do mesmo procedimento/item da mesma tabela dentro do
-- mesmo lançamento (Componente Organizacional) — decisão do usuário
-- 2026-09-23: CONSOLIDAR em 1 linha por conta+tabela+procedimento, somando
-- quantidade e valores, em vez de reportar linhas repetidas.
-- `itens_calculados` mantém o cálculo por item ORIGINAL (quantidade
-- paga/valor pago dependem do `vl_unitario` de CADA linha, que pode diferir
-- entre duplicatas — não dá pra somar unitários e recalcular depois);
-- `itens` agrupa por conta+tabela+procedimento somando os resultados já
-- calculados. Contas sem duplicata (a maioria) ficam com grupo de 1 item
-- só, comportamento idêntico ao anterior.
-- -----------------------------------------------------------------------------
itens_calculados AS (
    SELECT
        scmp.idsps_conta_medica,
        scmp.ie_tabela_tuss,                                    -- ✅
        p.cd_procedimento,                                      -- ✅
        scmp.cd_unidade_medida,                                 -- ✅
        scmp.qt_realizada,                                      -- ✅
        -- ✅ AJUSTE 2026-09-23 (nota 32) — achado numa 4ª análise externa e
        -- confirmado em produção: 9 itens (contas 3, 4, 5, únicas afetadas em
        -- toda a base Novamed) têm `vl_total_apresentado = 0` com
        -- `vl_unitario > 0` — a mesma linha já tem `vl_total_aprovado`
        -- corretamente preenchido com `vl_unitario × qt_realizada`, prova de
        -- que só a coluna "apresentado" ficou zerada no cadastro/lançamento
        -- do item, não uma ausência real de valor. Fallback recalcula com a
        -- MESMA fórmula que o próprio sistema já usa para `vl_total_aprovado`
        -- — não inventa valor novo, só usa o que já existe (`vl_unitario`,
        -- `qt_realizada`). Fecha 100% do gap conta×itens nas contas 3 e 5;
        -- a conta 4 fecha só parte do gap (R$1.200 de R$2.000) — os R$800
        -- residuais não têm explicação nos dados e ficam documentados como
        -- pendência de cadastro/faturamento, não corrigível via query.
        COALESCE(NULLIF(scmp.vl_total_apresentado, 0), scmp.vl_unitario * scmp.qt_realizada)
                                                                 AS vl_total_apresentado,
        COALESCE(scmp.vl_coparticipacao, 0)                     AS vl_coparticipacao,
        -- mesma fórmula de sempre (nota 25), calculada por item ORIGINAL
        -- antes do agrupamento — depende do `vl_unitario` de cada linha.
        CASE
            WHEN cp.tipo_evento_lancamento <> 'PAGO' THEN 0
            WHEN scmp.vl_unitario IS NULL OR scmp.vl_unitario = 0 THEN scmp.qt_realizada
            ELSE ROUND(COALESCE(scmp.vl_total_aprovado, 0) / scmp.vl_unitario, 4)
        END                                                      AS quantidade_paga_item,
        CASE WHEN cp.tipo_evento_lancamento = 'PAGO'
             THEN COALESCE(scmp.vl_total_aprovado, 0) ELSE 0 END AS valor_pago_item
    FROM sps_conta_medica_proc scmp
    INNER JOIN procedimento p ON p.idprocedimento = scmp.idprocedimento
                              AND p.status = 'A'                     -- ✅ nota 37
    INNER JOIN contas_periodo cp ON cp.idsps_conta_medica = scmp.idsps_conta_medica
    WHERE scmp.status = 'A'
),
itens AS (
    SELECT
        idsps_conta_medica,
        ie_tabela_tuss,
        cd_procedimento,
        MAX(cd_unidade_medida)             AS cd_unidade_medida,
        SUM(qt_realizada)                  AS qt_realizada,
        SUM(vl_total_apresentado)          AS vl_total_apresentado,
        SUM(vl_coparticipacao)             AS vl_coparticipacao,
        SUM(quantidade_paga_item)          AS quantidade_paga,
        SUM(valor_pago_item)               AS valor_pago_procedimento
    FROM itens_calculados
    GROUP BY idsps_conta_medica, ie_tabela_tuss, cd_procedimento
),
-- -----------------------------------------------------------------------------
-- ✅ AJUSTE 2026-09-23 (nota 34) — campo "valor total informado" (guia) deve
-- ser igual à soma dos itens do MESMO lançamento (mesma regra já usada para
-- coparticipação/pago na nota 29). Em vez de continuar lendo `cp.vl_apresentado`
-- (cabeçalho da conta, independente dos itens) e caçar caso a caso quando
-- diverge (achado das contas 3/4/5 desde 21/09/2026), esta CTE agrega o valor
-- REAL dos itens que o próprio CSV já está reportando por guia — a
-- consistência passa a valer por construção, para qualquer conta, presente ou
-- futura, sem precisar de fallback especial por conta. Decisão do usuário
-- 2026-09-23: equalizar SOMENTE no CSV (nenhum UPDATE em produção) — o valor
-- de cabeçalho real do sistema (`cp.vl_apresentado`) continua divergente na
-- base viva e a causa (indício de erro de digitação no item principal da
-- conta 4, ver nota 33-b) continua pendência de faturamento, não afetada por
-- este ajuste, que é só de apresentação no arquivo à ANS.
-- -----------------------------------------------------------------------------
totais_informado_guia AS (
    SELECT idsps_conta_medica, SUM(vl_total_apresentado) AS vl_total_informado_real
    FROM itens
    GROUP BY idsps_conta_medica
)
-- =============================================================================
-- SELECT final — uma linha por procedimento; colunas na MESMA ordem do
-- cabeçalho de examples/csv/guia_monitoramento.csv.
-- =============================================================================
SELECT
    'guia'                                                        AS tipo_bloco,
    CONCAT('CM', LPAD(cp.idsps_conta_medica, 10, '0'))            AS chave_registro,
    pr.tipo_registro                                              AS tipo_registro,
    pr.versao_tiss_prestador                                      AS versao_tiss_prestador,
    pr.forma_envio                                                AS forma_envio,
    -- ✅ AJUSTE 2026-08-19 — placeholder acordado com a operadora para contas
    -- sem CNES cadastrado (ver nota 12 no rodapé: PJ sem `cd_cnes` ou
    -- prestador PF sem estabelecimento-CNES vinculável). '9999999' tem 7
    -- dígitos — respeita o limite do campo (csv-layouts.js `executante_cnes:
    -- 7`) e do XSD; "99999999" (8 dígitos) trocaria o erro de campo
    -- obrigatório por um erro de tamanho excedido, por isso não foi usado.
    -- Cobre NULL, '0'/0 (CNES zerado não é código real) e também CNES REAL
    -- cadastrado mas com mais de 7 dígitos (achado em amostra: prestador
    -- idsps_prestador=2 tem cd_cnes='123456789', 9 dígitos — dado de
    -- cadastro inválido/dummy que sozinho já estourava o XSD; melhor cair
    -- no mesmo placeholder do que gerar erro de tamanho excedido).
    -- ✅ AJUSTE 2026-09-24 (nota 38) — achado numa 11ª análise externa do
    -- `.XTE` real de 05/2026: conta 183 (prestador Confiar - Centro de
    -- Oncologia e Física Aplicada a Radioterapia, CNPJ 26.044.170/0001-61)
    -- saía com `executante_cnes=500356` (6 dígitos) quando o CNES real
    -- cadastrado no DATASUS é `0500356` (7 dígitos, confirmado pela análise
    -- externa). Causa raiz confirmada em produção: `pessoa_juridica.cd_cnes`
    -- é coluna `INT`, que descarta silenciosamente qualquer zero à esquerda
    -- — o dado real gravado é `500356`, não um erro de digitação. Como todo
    -- CNES válido tem exatamente 7 dígitos (padrão DATASUS/ANS, mesmo
    -- critério já usado no placeholder acima), a correção é sempre
    -- devolver a representação com zero(s) à esquerda via `LPAD`, nunca o
    -- `CAST` cru. Levantamento Novamed-wide (não só 05/2026) achou mais 2
    -- prestadores no mesmo caso (`410691`→`0410691`, Amorim Serviços
    -- Médicos; `880418`→`0880418`, Centro Clínico de Ceres) — afeta
    -- qualquer competência em que esses 3 prestadores aparecerem, não só
    -- 05/2026. Mecânico (não inventa dígito novo, só restaura o zero que o
    -- tipo de coluna descarta) — sem necessidade de confirmação de negócio.
    CASE
        WHEN pd.cnes IS NULL
          OR CAST(pd.cnes AS CHAR) = '0'
          OR CHAR_LENGTH(CAST(pd.cnes AS CHAR)) > 7
        THEN '9999999'
        ELSE LPAD(CAST(pd.cnes AS CHAR), 7, '0')
    END                                                            AS executante_cnes,
    pd.tipo_identificacao_tiss                                    AS executante_tipo_identificacao,
    pd.cpf_cnpj                                                   AS executante_cpf_cnpj,
    LEFT(COALESCE(CAST(pd.municipio_ibge AS CHAR), ''), 6)        AS executante_municipio,
    NULL                                                          AS operadora_intermediaria_registro,
    NULL                                                          AS operadora_intermediaria_tipo_atendimento,
    bd.nr_cartao_nac_sus                                          AS beneficiario_cns,
    bd.nr_cpf                                                     AS beneficiario_cpf,
    bd.sexo_tiss                                                  AS beneficiario_sexo,
    DATE_FORMAT(bd.dt_nascimento, '%Y-%m-%d')                     AS beneficiario_data_nascimento,
    bd.municipio_ibge                                             AS beneficiario_municipio_residencia,
    bd.plano_registro                                             AS plano_registro,
    -- ✅ RESOLVIDO 2026-09-22 (nota 28 no rodapé) — `cm.ie_tipo_guia_tiss` é o
    -- domínio interno 831 (1=Consulta, 2/4/5=Internação/Prorrogação/Resumo,
    -- 3=SP/SADT, 6=Odontológico, 7=Honorário Individual, 8-11=OPME/
    -- Quimioterapia/Outras Despesas/Radioterapia), NÃO o domínio oficial ANS
    -- `dm_tipoEventoMonitoramento` (1=Consulta, 2=SP/SADT, 3=Internação,
    -- 4=Odontológico, 5=Honorários — confirmado no comentário embutido pela
    -- própria ANS dentro do XSD real). Um passthrough direto (como estava)
    -- declarava a esmagadora maioria das guias SP/SADT como "Internação" —
    -- achado ao auditar o XML real com registro ANS verdadeiro (278 das 279
    -- contas de 04/2026 afetadas). Crosswalk confirmado pelo usuário
    -- 2026-09-22, incluindo o bucket 8-11 (sem correspondência direta no
    -- domínio ANS de 5 valores) → SP/SADT, por analogia (anexos de OPME/
    -- quimio/radioterapia são tecnicamente parte do bloco SP/SADT no TISS).
    CASE cp.ie_tipo_guia_tiss
        WHEN '1' THEN '1'
        WHEN '3' THEN '2'
        WHEN '2' THEN '3'
        WHEN '4' THEN '3'
        WHEN '5' THEN '3'
        WHEN '6' THEN '4'
        WHEN '7' THEN '5'
        WHEN '8' THEN '2'
        WHEN '9' THEN '2'
        WHEN '10' THEN '2'
        WHEN '11' THEN '2'
        ELSE NULL
    END                                                            AS tipo_evento_atencao,
    -- ✅ RESOLVIDO 2026-09-22 — ver nota 13 no rodapé: fonte trocada de
    -- `cp.ie_origem_conta` (campo errado — método de digitação da conta,
    -- domínio 869) para `pd.origem_evento_atencao_ans`, derivado de
    -- `sps_prestador.ie_tipo_relacao_prestador` (domínio 843), mapeamento
    -- confirmado pelo usuário — ver comentário na CTE `prestador_dados`.
    pd.origem_evento_atencao_ans                                  AS origem_evento_atencao,
    -- ✅ confirmado via MCP MySQL (2026-08-17): não existe coluna própria de
    -- "número da guia na operadora" em sps_conta_medica nem em
    -- sps_autorizacao_guia — reaproveita nr_guia_prestador até que o sistema
    -- passe a gravar essa numeração separadamente.
    -- ✅ AJUSTE 2026-08-19 — `nr_guia_prestador` está vazio em ~98% das contas
    -- da base viva (149/152, confirmado via MCP MySQL) tanto na conta médica
    -- quanto na guia de autorização vinculada — o prestador simplesmente não
    -- preenche esse campo livre. Como o XSD exige o campo (obrigatório), cai
    -- para a PK interna (`idsps_conta_medica`, sempre não-nula e única) em
    -- vez de falhar a linha inteira. Isso é o número interno do sistema, não
    -- o número real do prestador — se a operadora passar a exigir o número
    -- real do prestador, esse fallback precisa ser revisto.
    -- ✅ AJUSTE 2026-09-22 — achado ao auditar o XML real com registro ANS
    -- verdadeiro, confirmado no PDF oficial (Componente de Conteúdo e
    -- Estrutura, novembro/2025, campo "Número da guia atribuído pela
    -- operadora", identificador ANS 024): "Quando a origem da guia for igual
    -- a 4-Reembolso ao beneficiário ou 5-Prestador eventual, o campo deve
    -- ser preenchido com '00000000000000000000' (20 zeros)". Aplicado a
    -- `numero_guia_operadora` (regra confirmada literalmente na fonte) e, por
    -- analogia/segurança, também a `numero_guia_prestador` (mesma exigência
    -- não achada de forma explícita nos 2 PDFs consultados para este campo
    -- específico — único ponto desta rodada de correções sem confirmação
    -- literal na fonte primária).
    CASE
        WHEN pd.origem_evento_atencao_ans IN ('4', '5') THEN REPEAT('0', 20)
        ELSE COALESCE(NULLIF(cp.nr_guia_prestador, ''), CAST(cp.idsps_conta_medica AS CHAR))
    END                                                            AS numero_guia_prestador,
    CASE
        WHEN pd.origem_evento_atencao_ans IN ('4', '5') THEN REPEAT('0', 20)
        ELSE COALESCE(NULLIF(cp.nr_guia_prestador, ''), CAST(cp.idsps_conta_medica AS CHAR))
    END                                                            AS numero_guia_operadora,
    -- ✅ AJUSTE 2026-09-22 — quando `origem_evento_atencao` é 4 ou 5, o
    -- validador do repositório exige `identificacao_reembolso` diferente de
    -- 20 zeros (parse-monitoring-csv.js) — efeito colateral do fix do
    -- `origem_evento_atencao` acima (22 linhas/5 contas só em 04/2026, mesmo
    -- padrão deve se repetir nas outras competências). Não é reembolso real
    -- ao beneficiário nesses casos (é só "prestador eventual"/fora da rede),
    -- então não existe um número de reembolso de fato — decisão do usuário
    -- 2026-09-22: usar `idsps_conta_medica` (mesmo padrão já usado acima para
    -- `numero_guia_prestador`/`numero_guia_operadora` quando o valor real não
    -- existe).
    CASE
        WHEN pd.origem_evento_atencao_ans IN ('4', '5')
        THEN LPAD(cp.idsps_conta_medica, 20, '0')
        ELSE REPEAT('0', 20)
    END                                                            AS identificacao_reembolso,
    NULL                                                          AS identificacao_valor_preestabelecido,
    -- ✅ AJUSTE 2026-09-23 (nota 36) — achado numa 9ª análise externa: campo
    -- 122/128 (Modelo de Remuneração, XML `formasRemuneracao`) estava
    -- hardcoded NULL desde a criação da query — nunca implementado (não é
    -- regressão de nenhuma correção anterior). Regra ANS (Monitora TISS,
    -- campos 122/128): obrigatório quando `origem_evento_atencao` é 1/2/3,
    -- exceto rede própria (3) do MESMO CNPJ da operadora; não preencher para
    -- 4/5. Verificado Novamed-wide (2026-09-23): nenhum registro de origem 3
    -- na base viva é o próprio CNPJ da Novamed (`59545401000170`, obtido via
    -- `estabelecimento.idpessoa_juridica` de `idestabelecimento=19`) — a
    -- exceção não se aplica hoje, mas o CASE já cobre o caso caso apareça no
    -- futuro. Investigação de fonte: nenhuma tabela do schema `producao`
    -- representa o conceito TISS de modelo de remuneração (fee-for-service/
    -- pacote/capitation/DRG) por prestador — `regra_preco`/`sps_contrato` são
    -- preço/contrato do BENEFICIÁRIO, `forma_pagamento`/`condicao_pagamento`
    -- são do módulo financeiro (boleto/cartão), sem relação com o conceito.
    -- Toda a base de faturamento médico é 100% por procedimento individual
    -- (`sps_conta_medica_proc`, `vl_unitario × qt_realizada`) — não há
    -- infraestrutura de pacote/capitation aplicada ao faturamento TISS em
    -- nenhum lugar do sistema. Decisão do usuário 2026-09-23 (pergunta
    -- explícita, mesmo critério da recusa de fabricar datas nas notas 33/34):
    -- declarar código `01` (Pós-pagamento por Procedimento) para todos os
    -- registros elegíveis — única modalidade sustentada pela arquitetura do
    -- sistema. Valor vinculado ao modelo = `valorTotalInformado` da própria
    -- guia (mesma fonte de `tig.vl_total_informado_real`/`cp.vl_apresentado`
    -- já usada na coluna `valor_total_informado`, nota 34) — como há só 1
    -- modelo por guia, a soma fecha 100% por definição, sem dividir valor
    -- entre modelos concorrentes.
    CASE
        WHEN pd.origem_evento_atencao_ans IN ('1', '2')
          OR (pd.origem_evento_atencao_ans = '3' AND pd.cpf_cnpj <> '59545401000170')
        THEN CONCAT('01:', CAST(COALESCE(tig.vl_total_informado_real, cp.vl_apresentado) AS DECIMAL(18, 2)))
        ELSE NULL
    END                                                            AS formas_remuneracao,
    NULL                                                          AS guia_solicitacao_internacao,
    NULL                                                          AS data_solicitacao,
    NULL                                                          AS numero_guia_spsadt_principal,
    DATE_FORMAT(cp.dt_autorizacao, '%Y-%m-%d')                    AS data_autorizacao,
    -- ✅ REDESENHADO 2026-09-22 (ver CTE `realizacao_conta` acima) —
    -- `data_realizacao` agora prioriza `MIN(sps_conta_medica_proc.dt_realizacao)`
    -- (data real de execução, item a item, 99,6% de cobertura) sobre
    -- `dt_inicio_faturamento`/`dt_autorizacao`/`dt_cadastro_conta` — o AJUSTE
    -- 2026-08-19 abaixo (ainda válido como ÚLTIMO recurso, ~0,4% dos casos)
    -- usava só o cadastro da conta como proxy de realização, o que inflava a
    -- data pra bem depois do atendimento real e fazia `dataProtocoloCobranca`/
    -- `dataProcessamentoGuia` (corretas) parecerem anteriores à "realização"
    -- (errada) — achado ao auditar o XML real de 04/2026 (145 e 87 contas
    -- respectivamente, confirmado via MCP MySQL).
    -- ✅ AJUSTE 2026-09-24 (nota 39) — achado/decisão do usuário a partir da
    -- conta 1035 (05/2026, `identificacaoReembolso...001035`, prestador
    -- eventual): em atendimento PARTICULAR, a equipe cadastra a conta e o
    -- protocolo ANTES de o paciente efetivamente comparecer à clínica (o
    -- protocolo agenda o atendimento, que só ocorre depois) — fluxo inverso
    -- do caso normal (paciente atende, depois a conta é protocolada), fazendo
    -- `dt_realizacao_real` (item) ficar genuinamente POSTERIOR ao protocolo
    -- nesses casos (mesmo padrão do resíduo cronológico de 16+1 guias já
    -- documentado, notas 35/38-c). Decisão do usuário: quando isso ocorre,
    -- declarar `data_realizacao` como a própria data do protocolo (nunca
    -- posterior a ela) — usa um dado REAL já existente no mesmo registro (não
    -- fabrica nada), resolvendo por construção a violação do campo 032
    -- ("dataProtocoloCobranca deve ser >= dataRealizacao") para esse padrão de
    -- negócio. `LEAST` entre a expressão já existente e a MESMA COALESCE
    -- usada abaixo em `data_protocolo_cobranca` — quando a realização real é
    -- anterior ou igual ao protocolo (caso normal, >99%), o resultado é
    -- idêntico a antes; só quando a realização cai DEPOIS do protocolo, o
    -- valor declarado passa a ser a data do protocolo.
    DATE_FORMAT(
        LEAST(
            COALESCE(rc.dt_realizacao_real, cp.dt_inicio_faturamento, cp.dt_autorizacao, cp.dt_cadastro_conta),
            COALESCE(ps.dt_recebimento, cp.dt_cadastro_conta, ps.dt_cadastro_protocolo, cp.dt_autorizacao)
        ),
        '%Y-%m-%d'
    )                                                              AS data_realizacao,
    -- ✅ AJUSTE 2026-08-19 — `dt_inicio_faturamento` E `dt_autorizacao` estão
    -- ambos NULL em ~81% das contas (123/152, confirmado via MCP MySQL);
    -- `cp.dt_cadastro_conta` (= `sps_conta_medica.dt_insert`) é NOT NULL por
    -- definição de coluna, garantindo que o campo obrigatório do XSD nunca
    -- fique vazio — mas é a data de CADASTRO da conta, não necessariamente a
    -- data real de realização do procedimento; tratar como último recurso,
    -- só usado agora quando nem `realizacao_conta` resolve (~0,4% dos casos).
    DATE_FORMAT(cp.dt_inicio_faturamento, '%Y-%m-%d')             AS data_inicial_faturamento,
    DATE_FORMAT(cp.dt_fim_faturamento, '%Y-%m-%d')                AS data_fim_periodo,
    -- ✅ AJUSTE 2026-09-23 (nota 32) — achado numa 4ª análise externa: 15
    -- guias de 04/2026 (mesmo padrão crescente em 05-07/2026) tinham
    -- `data_protocolo_cobranca` (então `ps.dt_cadastro_protocolo`, i.e.
    -- `sps_protocolo_conta_medica.dt_insert`) ANTERIOR à `data_realizacao`,
    -- violando o campo 032 do Componente de Conteúdo e Estrutura ("deve ser
    -- maior ou igual à Data de realização"). Causa raiz confirmada em
    -- produção: `sps_protocolo_conta_medica` é um registro de LOTE que
    -- agrupa várias contas médicas — nas 15 guias o lote foi cadastrado
    -- (`pcm.dt_insert`) ANTES de a própria conta médica existir (conta
    -- criada só 4-16 dias depois). `cp.dt_cadastro_conta`
    -- (`sps_conta_medica.dt_insert`) bate no MESMO DIA com `dt_realizacao`
    -- real nas 15 guias — muito mais fiel à semântica do campo 032 ("data
    -- que a operadora recebeu o lote de cobrança com a guia") do que a data
    -- de criação do LOTE em si. Decisão do usuário 2026-09-23: trocar a
    -- fonte para `cp.dt_cadastro_conta`, SEM mudar o evento
    -- AVISADO/competência (nota 25, continua usando `pcm.dt_insert` via
    -- `contas_evento_periodo` — decisão deliberadamente mantida, alinhada à
    -- query contábil de eventos). Validado Novamed-wide antes de aplicar:
    -- reduz violações de ordem cronológica em 05/2026 (26→1) e 06/2026
    -- (73→5), sem piorar nenhuma competência.
    DATE_FORMAT(
        COALESCE(ps.dt_recebimento, cp.dt_cadastro_conta, ps.dt_cadastro_protocolo, cp.dt_autorizacao),
        '%Y-%m-%d'
    )                                                              AS data_protocolo_cobranca,
    -- ✅ AJUSTE 2026-08-19 — `dt_recebimento` está NULL em 100% dos protocolos
    -- da base viva (152/152, confirmado via MCP MySQL) — nunca é gravado pela
    -- aplicação. `ps.dt_cadastro_protocolo` (NOT NULL) é o fallback mais
    -- próximo semanticamente; `cp.dt_autorizacao`/`cp.dt_cadastro_conta`
    -- seguram o caso raro de protocolo ausente.
    -- ✅ REDESENHADO 2026-09-22 — `data_pagamento` só é preenchida quando o
    -- evento vencedor DESTA competência é PAGO. Antes mostrava
    -- `cp.dt_pagamento` incondicionalmente (estado atual), o que vazava uma
    -- data de pagamento futura (de uma competência posterior) para dentro de
    -- um lançamento AVISADO/LIBERADO mais antigo — mesma classe do bug da
    -- nota 25 abaixo (regra ANS 259, dataProcessamentoGuia).
    -- ✅ AJUSTE 2026-09-24 (nota 38) — achado numa 11ª análise externa: conta
    -- 1035 (prestador eventual, `identificacaoReembolso...001035`) saía com
    -- `valorPagoGuia`/`valorTotalPagoProcedimentos` = R$11.067,88 (100% pago,
    -- corretamente gated por `tipo_evento_lancamento='PAGO'`) mas
    -- `data_pagamento` vazia — violação do campo 057, que exige a data quando
    -- há valor pago. Causa raiz confirmada em produção: `cp.dt_pagamento`
    -- (`=cm.dt_pagamento`, coluna crua de `sps_conta_medica`) está NULL para
    -- esta conta, mas o log (`sps_conta_medica_log`, evento '4',
    -- `ie_situacao='3'`, `idsps_conta_medica_log=15907`) confirma o
    -- pagamento real em 2026-05-27 18:38:14 — a mesma fonte que já define
    -- `tipo_evento_lancamento='PAGO'` (via `eventos_pagamento_ranqueados` /
    -- `contas_evento_periodo`). `cm.dt_pagamento` é uma coluna legada que não
    -- é atualizada de forma confiável pelo fluxo operacional (mesma classe de
    -- achado das notas 25/32: o log é a fonte de verdade, não a coluna crua
    -- do estado atual). Corrigido trocando a fonte para
    -- `cp.dt_evento_lancamento` — o mesmo valor já usado em
    -- `data_processamento_guia` quando o evento vencedor é PAGO, garantindo
    -- por construção que `data_pagamento = data_processamento_guia` nesse
    -- caso (consistente com a regra ANS de que o pagamento não pode ser
    -- anterior ao processamento). Mecânico — usa dado já computado na mesma
    -- linha, não inventa nada.
    CASE WHEN cp.tipo_evento_lancamento = 'PAGO'
         THEN DATE_FORMAT(cp.dt_evento_lancamento, '%Y-%m-%d')
    END                                                            AS data_pagamento,
    -- ✅ REDESENHADO 2026-09-22 (nota 25 no rodapé) — `dataProcessamentoGuia`
    -- agora é a data do PRÓPRIO evento vencedor desta competência
    -- (`cp.dt_evento_lancamento`: dt_insert do protocolo se AVISADO, data da
    -- transição de log se LIBERADO/PAGO) — não mais um COALESCE de datas do
    -- estado ATUAL da conta, que podia cair num mês diferente da competência
    -- do arquivo e violar a regra ANS 259 (mês/ano da data de processamento
    -- deve bater com o mês/ano da competência do arquivo, senão o arquivo
    -- inteiro é rejeitado). Substitui o AJUSTE 2026-09-22 anterior (fallback
    -- para dt_cadastro_conta) — não é mais necessário: o evento vencedor
    -- sempre tem uma data própria dentro do período pedido.
    DATE_FORMAT(cp.dt_evento_lancamento, '%Y-%m-%d')              AS data_processamento_guia,
    -- ✅ AJUSTE 2026-09-24 (nota 40) — achado 38-e (225 guias de 05/2026 sem
    -- `tipo_consulta`, gap real de cadastro em maio/2026, sem bug de query).
    -- Decisão explícita do usuário: quando a guia é do tipo CONSULTA
    -- (`cp.ie_tipo_guia_tiss = '1'`, mesmo domínio 831 usado no crosswalk de
    -- `tipo_evento_atencao` acima) e `ie_tipo_consulta` vier vazio, assumir o
    -- padrão `1` (verificado no XSD real, `dm_tipoConsulta`: 1=Primeira,
    -- 2=Seguimento, 3=Pré-Natal, 4=Por encaminhamento — código `1` = Primeira
    -- Consulta). Escopo restrito a guias de Consulta (não abrange os 3
    -- SP/SADT com `tipo_atendimento='04'` também citados na nota 38-e, que
    -- não são "tipo de guia Consulta" — ficam sem alteração, mesmo critério
    -- de seguir o pedido literalmente). Quando `ie_tipo_consulta` já vem
    -- preenchido (qualquer guia), o valor original é mantido sem alteração.
    CASE
        WHEN cp.ie_tipo_guia_tiss = '1' THEN COALESCE(cp.ie_tipo_consulta, '1')
        ELSE cp.ie_tipo_consulta
    END                                                            AS tipo_consulta,
    -- ✅ AJUSTE 2026-09-23 (nota 30) — campo 035 do Componente de Conteúdo e
    -- Estrutura ANS: "Lançamento com CBO igual a 999999 será rejeitado, pois
    -- esse código só deve ser utilizado na troca entre operadoras e
    -- prestadores... não deve ser enviado pela operadora [à ANS]." O mesmo
    -- campo é CONDICIONADO (só obrigatório quando tipo de guia = Consulta/
    -- SP-SADT E tipo de atendimento = 4-Consulta E origem ∈ {1,2,3}) — as 9
    -- ocorrências achadas em 04/2026 (contas 100, 362, 427, 429, 439, 459,
    -- 460, 461, 949) são todas de laboratórios (Hemolabor, Laboratório
    -- Saúde) com `ie_tipo_atendimento_tiss` = 8 ou 23 (nunca 4) — CBO nem é
    -- obrigatório nesses casos. `NULLIF` remove o literal proibido sempre
    -- (regra absoluta da ANS, não condicional) — se algum dia um caso onde o
    -- CBO É obrigatório tiver `cd_cbo='999999'`, o resultado é o validador
    -- acusar campo obrigatório ausente (honesto: não temos o CBO real),
    -- nunca o envio de um valor garantidamente rejeitado.
    NULLIF(cp.cd_cbo, '999999')                                   AS cbo_executante,
    cp.ie_atendimento_rn                                          AS indicacao_recem_nato,
    cp.ie_indicador_acidente_tiss                                 AS indicacao_acidente,
    cp.ie_carater_atendimento_tiss                                AS carater_atendimento,
    cp.ie_tipo_internacao_tiss                                    AS tipo_internacao,
    cp.ie_regime_internacao                                       AS regime_internacao,
    NULLIF(
        CONCAT_WS('|',
            NULLIF(cp.cd_cid_doenca_princ, ''),
            NULLIF(cp.cd_cid_doenca_seg, ''),
            NULLIF(cp.cd_cid_doenca_terc, ''),
            NULLIF(cp.cd_cid_doenca_quar, '')
        ),
        ''
    )                                                              AS diagnosticos_cid10,
    -- ✅ AJUSTE 2026-09-21 — mesmo problema do `regime_atendimento` (nota abaixo):
    -- `ie_tipo_atendimento_tiss` é gravado sem zero à esquerda ('1','2','3'...
    -- confirmado via MCP MySQL contra o banco vivo, idestabelecimento=19); o
    -- domínio do XSD 01.06.00 exige '01'..'23'. Achado na auditoria estrutural
    -- da competência 04/2026 (2026-09-21): 24 linhas rejeitadas pelo validador
    -- do repositório por esse motivo. LPAD resolve sem tocar no dado de origem.
    LPAD(cp.ie_tipo_atendimento_tiss, 2, '0')                     AS tipo_atendimento,
    -- ✅ AJUSTE 2026-08-19 — `ie_regime_atendimento_tiss` é `char(2)` mas a
    -- aplicação grava sem zero à esquerda ('1','2','4', confirmado via MCP
    -- MySQL); o domínio do XSD 01.06.00 exige '01'..'05'. LPAD resolve sem
    -- tocar no dado de origem; não altera linhas já NULL (obrigatório
    -- ausente continua sendo outro erro, tratado à parte).
    LPAD(cp.ie_regime_atendimento_tiss, 2, '0')                   AS regime_atendimento,
    cp.ie_saude_ocupacional_tiss                                  AS saude_ocupacional,
    cp.ie_tipo_faturamento_tiss                                   AS tipo_faturamento,
    NULL                                                          AS diarias_acompanhante,
    NULL                                                          AS diarias_uti,
    cp.ie_motivo_encerramento_tiss                                AS motivo_saida,
    -- ✅ REDESENHADO 2026-09-22 (nota 25) — `valor_processado`/`valor_glosa_guia`/
    -- os 6 `valor_total_*_procedimentos` (tg.*) só aparecem quando o evento
    -- vencedor desta competência é LIBERADO ou PAGO. Num lançamento AVISADO
    -- (conta ainda não analisada, decisão do usuário 2026-09-22), esses
    -- valores são 0 — mesmo que a conta já tenha sido liberada/paga
    -- DEPOIS (isso pertence ao lançamento da competência em que aquele
    -- evento ocorreu, não a este). Antes, essas colunas usavam o estado
    -- ATUAL da conta incondicionalmente.
    -- ✅ AJUSTE 2026-09-23 (nota 34) — ver CTE `totais_informado_guia`: usa a
    -- soma real dos itens reportados nesta guia em vez do cabeçalho
    -- `cp.vl_apresentado`, garantindo por construção a regra ANS "valor total
    -- informado = soma dos itens do lançamento". COALESCE mantido só como
    -- rede de segurança (não deve disparar: toda linha do SELECT final já
    -- exige INNER JOIN com `itens`).
    CAST(COALESCE(tig.vl_total_informado_real, cp.vl_apresentado) AS DECIMAL(18, 2))
                                                                   AS valor_total_informado,
    -- ✅ AJUSTE 2026-09-23 (nota 29) — campo 051 do Componente de Conteúdo e
    -- Estrutura ANS (nov/2025): "Valor total processado pela operadora.
    -- Corresponde ao valor informado da guia MENOS o valor de glosa da
    -- guia." A fórmula anterior (`vl_liberado + vl_glosado`) reconstruía
    -- `vl_apresentado` quase sempre (identidade contábil confirmada em
    -- produção: vl_liberado + vl_glosado = vl_apresentado em 7.501/7.512
    -- contas da Novamed, 99,85%) e ainda zerava por completo no lançamento
    -- AVISADO — reproduzido em 218/279 guias de 04/2026. Fórmula corrigida
    -- usa diretamente informado − glosa; como `valor_glosa_guia` já é 0 no
    -- AVISADO (glosa ainda não apurada), o resultado no AVISADO passa a ser
    -- o próprio valor informado — coerente com a regra de que uma guia
    -- apresentada deve aparecer com o valor apresentado e só o PAGO zerado.
    -- ✅ AJUSTE 2026-09-23 (nota 34) — base trocada de `cp.vl_apresentado` para
    -- `tig.vl_total_informado_real` (mesma CTE usada em `valor_total_informado`
    -- acima), para as duas colunas continuarem coerentes entre si mesmo quando
    -- o cabeçalho da conta diverge da soma dos itens.
    CAST(
        COALESCE(tig.vl_total_informado_real, cp.vl_apresentado)
        - CASE WHEN cp.tipo_evento_lancamento IN ('LIBERADO', 'PAGO')
               THEN cp.vl_glosado ELSE 0 END
        AS DECIMAL(18, 2)
    )                                                              AS valor_processado,
    -- ✅ AJUSTE 2026-09-23 (nota 29) — os 6 `valor_total_pago_*` (campos
    -- 052-057) são, pelo nome e pela regra ANS ("quando não houver valor
    -- PAGO... preencher com zero"; campo 059 exige soma igual ao campo 073
    -- "Valor pago..." do MESMO lançamento, já gated `= 'PAGO'` no item,
    -- ver `valor_pago_procedimento` abaixo), valores de PAGAMENTO real —
    -- não de aprovação/liberação. Estavam gated `IN ('LIBERADO','PAGO')`
    -- enquanto `valor_pago_guia` e o campo de item já eram `= 'PAGO'` —
    -- inconsistência reproduzida em 61/279 guias de 04/2026 (LIBERADO
    -- mostrando pago_procedimentos > 0 com valor_pago_guia = 0). Gating
    -- corrigido para `= 'PAGO'`, igual às duas colunas que já estavam certas.
    CAST(
        CASE WHEN cp.tipo_evento_lancamento = 'PAGO'
             THEN COALESCE(tg.vl_pago_procedimentos, 0) ELSE 0 END
        AS DECIMAL(18, 2)
    )                                                              AS valor_total_pago_procedimentos,
    CAST(
        CASE WHEN cp.tipo_evento_lancamento = 'PAGO'
             THEN COALESCE(tg.vl_diarias, 0) ELSE 0 END
        AS DECIMAL(18, 2)
    )                                                              AS valor_total_diarias,
    CAST(
        CASE WHEN cp.tipo_evento_lancamento = 'PAGO'
             THEN COALESCE(tg.vl_taxas, 0) ELSE 0 END
        AS DECIMAL(18, 2)
    )                                                              AS valor_total_taxas,
    CAST(
        CASE WHEN cp.tipo_evento_lancamento = 'PAGO'
             THEN COALESCE(tg.vl_materiais, 0) ELSE 0 END
        AS DECIMAL(18, 2)
    )                                                              AS valor_total_materiais,
    CAST(
        CASE WHEN cp.tipo_evento_lancamento = 'PAGO'
             THEN COALESCE(tg.vl_opme, 0) ELSE 0 END
        AS DECIMAL(18, 2)
    )                                                              AS valor_total_opme,
    CAST(
        CASE WHEN cp.tipo_evento_lancamento = 'PAGO'
             THEN COALESCE(tg.vl_medicamentos, 0) ELSE 0 END
        AS DECIMAL(18, 2)
    )                                                              AS valor_total_medicamentos,
    CAST(
        CASE WHEN cp.tipo_evento_lancamento IN ('LIBERADO', 'PAGO')
             THEN cp.vl_glosado ELSE 0 END
        AS DECIMAL(18, 2)
    )                                                              AS valor_glosa_guia,
    CAST(
        CASE WHEN cp.tipo_evento_lancamento = 'PAGO' THEN cp.vl_liberado ELSE 0 END
        AS DECIMAL(18, 2)
    )                                                              AS valor_pago_guia,
    CAST(0.00 AS DECIMAL(18, 2))                                  AS valor_pago_fornecedores,
    CAST(0.00 AS DECIMAL(18, 2))                                  AS valor_total_tabela_propria,
    -- ✅ AJUSTE 2026-09-23 (nota 29) — campo 084 do Componente de Conteúdo e
    -- Estrutura ANS: deve ser igual à soma do valor de coparticipação
    -- (campo 085) dos itens do MESMO lançamento (guia de Consulta/SP-SADT
    -- não internado/Odonto; para Internação/Honorários deve ser zero, o que
    -- já ocorre naturalmente porque o dado de origem não popula
    -- coparticipação de item nesses casos). Antes usava `cp.vl_coparticipacao`
    -- — coluna de CABEÇALHO independente dos itens — que divergia da soma
    -- real dos itens em 162/279 guias de 04/2026. Trocado para somar os
    -- itens de verdade (`tg.vl_coparticipacao_total`, CTE `totais_guia`).
    CAST(COALESCE(tg.vl_coparticipacao_total, 0.00) AS DECIMAL(18, 2))
                                                                   AS valor_total_coparticipacao,
    cp.nr_declaracao_nascido_vivo                                 AS declaracoes_nascido,
    cp.nr_declaracao_obito                                        AS declaracoes_obito,
    it.ie_tabela_tuss                                             AS procedimento_codigo_tabela,
    NULL                                                          AS procedimento_grupo,
    it.cd_procedimento                                            AS procedimento_codigo,
    NULL                                                          AS dente_codigo,
    NULL                                                          AS regiao_codigo,
    NULL                                                          AS dente_face,
    CAST(it.qt_realizada AS DECIMAL(18, 4))                       AS quantidade_informada,
    CAST(it.vl_total_apresentado AS DECIMAL(18, 2))               AS valor_informado,
    -- ✅ AJUSTE 2026-09-22 — achado na auditoria de 06/2026 e 07/2026 (conta
    -- 1209, item 8746, confirmado via MCP MySQL): protocolo já Pago
    -- (`ie_situacao='3'`) mas `vl_total_aprovado` do item NULL, não 0.00 —
    -- valor de glosa da conta bate exatamente com `vl_total_apresentado`
    -- desse item, ou seja, é um item 100% glosado cujo `vl_total_aprovado`
    -- nunca foi zerado pela aplicação (deveria ser 0.00, não NULL). Como esta
    -- coluna só é avaliada quando o lançamento é PAGO (ver REDESENHO
    -- 2026-09-22, nota 25), NULL aqui só pode significar "zero aprovado",
    -- nunca "ainda não analisado" — COALESCE para 0 é seguro nesse ponto.
    --
    -- ✅ REDESENHADO 2026-09-22 (nota 25), REAGRUPADO 2026-09-23 (nota 31) —
    -- `quantidade_paga`/`valor_pago_procedimento` já vêm SOMADOS por item
    -- original na CTE `itens` (ver nota 31) — cada item original já é
    -- gated `= 'PAGO'` antes de somar, então a coluna aqui só precisa do
    -- CAST final.
    CAST(it.quantidade_paga AS DECIMAL(18, 4))                    AS quantidade_paga,
    it.cd_unidade_medida                                          AS unidade_medida,
    CAST(it.valor_pago_procedimento AS DECIMAL(18, 2))            AS valor_pago_procedimento,
    CAST(0.00 AS DECIMAL(18, 2))                                  AS valor_pago_fornecedor,
    NULL                                                          AS fornecedor_cnpj,
    CAST(it.vl_coparticipacao AS DECIMAL(18, 2))                  AS valor_coparticipacao_procedimento,
    NULL                                                          AS detalhes_pacote
FROM contas_periodo cp
CROSS JOIN parametros pr
INNER JOIN itens it              ON it.idsps_conta_medica = cp.idsps_conta_medica
LEFT JOIN protocolo_situacao ps  ON ps.idsps_protocolo_conta_medica = cp.idsps_protocolo_conta_medica
LEFT JOIN beneficiario_dados bd  ON bd.idsps_beneficiario = cp.idsps_beneficiario
LEFT JOIN prestador_dados pd     ON pd.idsps_prestador = cp.idsps_prestador_exec
LEFT JOIN totais_guia tg         ON tg.idsps_conta_medica = cp.idsps_conta_medica
LEFT JOIN realizacao_conta rc    ON rc.idsps_conta_medica = cp.idsps_conta_medica
LEFT JOIN totais_informado_guia tig ON tig.idsps_conta_medica = cp.idsps_conta_medica
ORDER BY
    -- ✅ AJUSTE 2026-09-23 (nota 31) — `it.idsps_conta_medica_proc` deixou de
    -- existir na CTE `itens` (agrupada por conta+tabela+procedimento, não
    -- mais 1 linha por PK de item); ordenar por tabela+procedimento mantém
    -- saída determinística equivalente.
    cp.idsps_conta_medica,
    it.ie_tabela_tuss,
    it.cd_procedimento;
-- =============================================================================
-- Validação via MCP MySQL contra o banco vivo (schema `dados`, 2026-08-17) —
-- resolve a maior parte das pendências 🔴/🟡 da sessão anterior:
--
-- 1. ✅ RESOLVIDO — `prestador_dados` agora obtém o município via
--    `pessoa_juridica.cep` / `pessoa_fisica_compl.cep` → `logradouro` →
--    `municipio.cd_ibge` (CTEs `prestador_endereco_pj`/`prestador_endereco_pf`),
--    o mesmo mecanismo já usado para o beneficiário. As colunas antes supostas
--    (`pj.cd_municipio_ibge`/`pf.cd_municipio_ibge`) foram confirmadas
--    INEXISTENTES via `SHOW CREATE TABLE` — teriam causado erro em produção.
--    `pessoa_juridica` também tem `ds_municipio`/`sg_uf` (texto livre, sem FK),
--    descartado em favor do caminho por CEP, mais confiável.
-- 2. ✅ RESOLVIDO — `nr_guia_operadora` foi confirmado INEXISTENTE tanto em
--    `sps_conta_medica` quanto em `sps_autorizacao_guia` via `SHOW CREATE
--    TABLE`. `numero_guia_operadora` no SELECT final passou a reaproveitar
--    `nr_guia_prestador` diretamente (sem COALESCE morto).
-- 3. ✅ RESOLVIDO — `sps_prestador.idpessoa_fisica` CONFIRMADO existente
--    (`bigint`, FK → `pessoa_fisica`); o LEFT JOIN em `prestador_dados` está
--    correto como estava.
-- 4. Os indicadores `ie_*_tiss` (tipo_consulta, indicacao_acidente,
--    carater_atendimento, tipo_internacao, regime_*, saude_ocupacional,
--    tipo_faturamento, motivo_saida, tipo_evento_atencao, origem_evento_atencao)
--    são copiados como estão. O nome de cada coluna espelha 1:1 a terminologia
--    das tabelas de domínio TISS correspondentes, o que sugere fortemente que
--    já armazenam o código padrão ANS — mas isso AINDA não foi validado contra
--    `dominio_valor` (ver pendências em modelagem.md §9). Antes do primeiro
--    envio real, confira uma amostra desses códigos contra o Componente
--    Organizacional do TISS 01.06.00 (docs/ans/).
-- 5. `plano_registro` (numeroRegistroPlano) usa `sps_produto.nr_protocolo_ans`,
--    o mesmo campo usado na geração do arquivo SIB para "numeroPlanoANS" —
--    alta confiança, mas confirme que é o registro do PRODUTO (RPS) e não do
--    plano individual do beneficiário, caso a operadora distinga os dois.
-- 6. ✅ RESOLVIDO (com correção) — `eventos_liberacao_ranqueados` originalmente
--    usava `ie_autorizacao_evento_log = '4'` (mesmo evento do PAGO) por
--    analogia. Amostra real mostrou que ISSO NUNCA CASA: o evento '4' só
--    carrega `valor='3'` (pago) na base viva (2 ocorrências, ambas maio/2026);
--    a transição para `valor='2'` (liberado) é gravada sob o evento **'9'**
--    (Análise Finalizada), com 44 ocorrências reais confirmadas — corrigido no
--    arquivo. Contagem de conferência para a competência 202607 (mês mais
--    recente com dados): 13 contas via AVISADO, 33 via LIBERADO (evento '9'),
--    0 via PAGO (os únicos 2 pagamentos reais da base ocorreram em maio/2026).
-- 7. `:competencia` é o único filtro de período aceito agora (formato AAAAMM,
--    mesmo valor do `--competencia` do CLI) — os antigos `:dt_inicio`/`:dt_fim`
--    livres foram removidos para impedir que o conteúdo do CSV cubra um
--    período diferente da competência declarada no nome do arquivo `.XTE`
--    gerado a partir dele.
-- -----------------------------------------------------------------------------
-- Ajustes 2026-08-19 — diagnóstico de error/inconsistencia_padrao_260819.txt
-- (42k+ linhas de erro, mesmos 7 problemas repetidos em ~100% das 152 contas/
-- 6633 itens da base viva, schema `dados`) via MCP MySQL. Resultado: a maior
-- parte dos erros era SISTÊMICA (mesma causa em toda linha), não sujeira
-- pontual de dado — sinal de que valia a pena corrigir na query, não CSV a
-- CSV. Itens efetivamente corrigidos nesta revisão (ver comentários inline
-- nas colunas correspondentes do SELECT final):
--   8. ✅ RESOLVIDO — `numero_guia_prestador`/`numero_guia_operadora` vazios
--      em 149/152 contas → fallback para `idsps_conta_medica` (PK, sempre
--      não-nula e única).
--   9. ✅ RESOLVIDO — `data_realizacao` NULL em 123/152 contas (ambas as
--      colunas-fonte NULL) → fallback final para `dt_insert` da conta médica
--      (NOT NULL).
--  10. ✅ RESOLVIDO — `data_protocolo_cobranca` NULL em 152/152 (via
--      `dt_recebimento`, nunca gravado pela aplicação) → fallback para
--      `dt_insert` do protocolo (NOT NULL), com `dt_autorizacao` como rede de
--      segurança adicional.
--  11. ✅ RESOLVIDO — `regime_atendimento` fora do domínio (valores '1'/'2'/
--      '4' sem zero à esquerda; XSD exige '01'..'05') → `LPAD(..., 2, '0')`.
--
--  12. ✅ RESOLVIDO (com placeholder acordado com a operadora, 2026-08-19) —
--      `executante_cnes` NULL em praticamente todas as contas: raiz real é
--      `pessoa_juridica.cd_cnes` vazio para 7 dos 8 prestadores cadastrados
--      (inclusive os dois estabelecimentos-tenant testados), e prestadores
--      Pessoa Física (a maioria das contas) não têm CNES próprio no modelo
--      (CNES é atributo de estabelecimento, não de profissional) — não há
--      vínculo PF→estabelecimento-PJ-com-CNES para usar como fallback real.
--      Decisão de negócio: usar `'9999999'` (7 noves — respeita `max: 7` de
--      `csv-layouts.js`/XSD; `'99999999'` com 8 dígitos foi descartado por
--      estourar o tamanho do campo) como marcador de "CNES não disponível"
--      até a operadora cadastrar os CNES reais (PJs) ou definir o CNES do
--      consultório para os profissionais autônomos. Mesmo placeholder
--      também cobre CNES > 7 dígitos (achado em amostra: idsps_prestador=2
--      tem `cd_cnes='123456789'`, cadastro inválido/dummy de 9 dígitos).
--      Ver `nota.txt` do projeto: "Ver CNES para prestador PF" e "Levantar
--      o CNES para todos os PJ como obrigatório no setor de cadastros" —
--      ambos já rastreiam esse pendente com a área de cadastros.
--
-- Item que PERMANECE pendente de decisão de negócio — não corrigido nesta
-- revisão porque um mapeamento errado no SELECT criaria um erro NOVO (e mais
-- silencioso, pois passaria pelo XSD) em vez de eliminar o atual:
--  13. ✅ RESOLVIDO 2026-09-22 — `origem_evento_atencao` fora do domínio 1-5
--      em 100% das contas de todas as competências geradas (04 a 07/2026).
--      Causa raiz real: a fonte usada até então (`sps_conta_medica.
--      ie_origem_conta`) era o campo ERRADO — é o domínio 869 ("Origem do
--      protocolo de contas médicas": D=Digitação Manual, S=Importação Guia
--      do Sistema, X=Importação XML), que descreve MÉTODO DE DIGITAÇÃO da
--      conta, sem nenhuma relação com rede de prestador. Antes de escrever
--      qualquer correção, verificamos via MCP MySQL (mysql-homologacao,
--      2026-09-22) se havia trigger bloqueando UPDATE em `sps_conta_medica`
--      (havia — `trg_sps_conta_medica_before_update` só permite editar conta
--      com `ie_situacao='1'`, bloqueando ~95% da base já liberada/paga) — a
--      investigação de trigger foi o que revelou que a premissa inicial
--      (corrigir dado em `ie_origem_conta` via UPDATE) estava errada; um
--      UPDATE ali teria corrompido um campo operacional legítimo e ainda
--      assim não resolveria o problema (domínio errado, não valor errado).
--      Fonte corrigida para `sps_prestador.ie_tipo_relacao_prestador`
--      (domínio 843), já usado com o mesmo propósito na query contábil de
--      eventos (query_diops_dados_eventos_v2.sql, coluna "rede") — ver CASE
--      em `origem_evento_atencao_ans` na CTE `prestador_dados`. Mapeamento
--      843→ANS confirmado pelo usuário 2026-09-22 (só para os 3 valores
--      presentes na base viva de idestabelecimento=19): 1→1, 6→3, 4→5.
--      Validado: 0 erros de `origem_evento_atencao` em 04/2026 (2.067
--      linhas). Efeito colateral resolvido junto: mapear para o domínio 5
--      exige `identificacao_reembolso` não-zero (ver ajuste na própria
--      coluna, mesmo padrão de fallback para `idsps_conta_medica` já usado
--      em `numero_guia_prestador`/`numero_guia_operadora`).
-- -----------------------------------------------------------------------------
-- Ajuste 2026-09-21 — auditoria de sincronismo entre esta query e a query
-- contábil de exportação de eventos (10_PROJETOS/exportacao-contabilidade-
-- novamed-integra/ANEXOS/scripts/query_diops_dados_eventos_v2.sql):
--  14. ✅ RESOLVIDO — o evento AVISADO usava `sps_conta_medica.dt_insert`
--      (data de cadastro da CONTA), mas tanto o relatório-fonte ("SPS - Custo
--      Médico do usuário por prestador.txt", CTE `contas_avisadas_pagas`)
--      quanto a query contábil de eventos (coluna `data_aviso`) usam
--      `sps_protocolo_conta_medica.dt_insert` (data de cadastro do
--      PROTOCOLO). Como um protocolo pode ser cadastrado em data diferente
--      das contas médicas vinculadas a ele, a divergência podia fazer esta
--      query incluir/excluir contas de uma competência de forma diferente do
--      que a contabilidade considera "avisado" — quebrando o sincronismo
--      exigido entre os dois processos (envio TISS e exportação contábil de
--      eventos). Corrigido para `pcm.dt_insert` em `contas_avisadas_periodo`,
--      alinhando os 3 estágios (avisado/liberado/pago) desta query com a
--      contábil. LIBERADO permanece exclusivo desta query (rastreado por log
--      evento '9') — não existe equivalente na exportação contábil, que não
--      precisa dessa granularidade. PAGO já estava sincronizado (mesmo
--      mecanismo de log evento '4' nas duas queries).
--
--      Decisão de escopo tomada na mesma auditoria (2026-09-21): o sistema
--      também tem um campo próprio de competência (`sps_lote_conta_medica.
--      mes_referencia`, documentado em modelagem.md §5 como "Competência do
--      lote"). Para 04/2026 ele retorna 702 contas contra as 279 do critério
--      evento-no-mês acima — decisão consciente do usuário de MANTER
--      evento-no-mês como critério de inclusão do Monitoramento TISS, não
--      trocar para `mes_referencia` (registrado em DECISOES.md do projeto
--      10_PROJETOS/envio-dados-tiss-competencia-07-2026).
-- -----------------------------------------------------------------------------
-- Ajustes 2026-09-21 — 1ª geração real de teste (competência 202604, 279
-- contas, 2067 itens) rodada e auditada contra produção (idestabelecimento=19).
-- Auditoria de valores: reconciliação por protocolo 100% correta (SOMA das
-- contas do escopo por protocolo bate exatamente com
-- `sps_protocolo_conta_medica.vl_apresentado`, nenhuma conta duplicada/faltante
-- dentro de um protocolo tocado). Sem linha duplicada no CSV gerado.
-- Validação estrutural (gerador do repositório, XSD 01.06.00) encontrou e
-- resolveu 2 bugs de domínio/obrigatoriedade:
--  15. ✅ RESOLVIDO — `tipo_atendimento` (`ie_tipo_atendimento_tiss`) gravado
--      sem zero à esquerda ('1','2','3'...), mesma classe de bug do item 11
--      (`regime_atendimento`) — 24 linhas rejeitadas pelo XSD (domínio exige
--      '01'..'23'). Corrigido com `LPAD(..., 2, '0')`, mesmo padrão já usado
--      em `regime_atendimento`.
--  16. ✅ RESOLVIDO — `valor_total_coparticipacao` (`cp.vl_coparticipacao`)
--      NULL em 333 contas da base viva (idestabelecimento=19) — campo
--      obrigatório do XSD ficava vazio. Corrigido com
--      `COALESCE(cp.vl_coparticipacao, 0.00)`, mesmo padrão de fallback zero
--      já usado em `valor_pago_fornecedores`/`valor_total_tabela_propria`.
--
-- Itens que PERMANECEM bloqueando a transmissão real de 04/2026 — não são bug
-- de JOIN/lógica desta query (os valores lidos do banco estão corretos), são
-- LACUNA DE CADASTRO na base ou DECISÃO DE NEGÓCIO ainda pendente, então não
-- foram "resolvidos" aqui para não inventar dado que a query não tem como
-- saber:
--  17. ✅ RESOLVIDO 2026-09-22 — `executante_municipio` vazio em 1.746 das
--      2.067 linhas (84%) da geração de teste de 04/2026, 1.740 delas de UM
--      ÚNICO prestador (Laboratório Saúde Ltda, CNPJ 91.671.792/0001-81),
--      cuja `pessoa_juridica.cep` estava NULL (idpessoa_juridica=90,
--      confirmado via MCP MySQL 2026-09-21). Johnathan corrigiu o cadastro em
--      produção (novo registro `pessoa_juridica`, idpessoa_juridica=1184,
--      mesmo CNPJ, CEP 90230020 → resolve para Porto Alegre/RS). Reprocessado
--      e validado 2026-09-22: 0 erros de `executante_municipio` no CSV de
--      04/2026 (population/contagem de contas idêntica: 279 contas, 2.067
--      itens, sem redundância nem falta de registro).
--  18. ✅ RESOLVIDO 2026-09-22 — `beneficiario_municipio_residencia` vazio em
--      168 linhas / 17 beneficiários distintos da geração de teste de
--      04/2026 (mesma causa raiz do item 17: endereço sem CEP resolvível via
--      `logradouro`). Johnathan corrigiu os 17 cadastros em produção.
--      Reprocessado e validado 2026-09-22: 0 erros de
--      `beneficiario_municipio_residencia` no CSV de 04/2026 (population
--      idêntica: 279 contas, 2.067 itens, sem redundância nem falta de
--      registro). Único erro estrutural remanescente em 04/2026 é o item 13
--      (`origem_evento_atencao`, decisão de negócio, não cadastro).
-- -----------------------------------------------------------------------------
-- Ajustes 2026-09-22 — auditoria das competências 06/2026 e 07/2026 (2.183 e
-- 2.412 contas):
--  19. ✅ RESOLVIDO — `quantidade_paga`/`valor_pago_procedimento` vazios
--      quando um item está 100% glosado dentro de um protocolo já Pago
--      (achado: conta 1209, item 8746 — `vl_total_aprovado` NULL em vez de
--      0.00, confirmado via MCP MySQL). Como essas colunas só usam
--      `vl_total_aprovado` quando `ps.protocolo_pago` é verdadeiro (análise já
--      encerrada), NULL nesse ponto só pode significar "zero aprovado" —
--      `COALESCE(it.vl_total_aprovado, 0)` aplicado nas duas colunas.
--  20. ✅ RESOLVIDO — `data_processamento_guia` vazia em contas AVISADAS mas
--      ainda em análise (`ie_situacao='1'`, achado: contas 2572/2573/3580 de
--      07/2026) — `dt_fim_analise`, `dt_liberacao_protocolo` e
--      `dt_autorizacao` legitimamente NULL nesse estágio. Adicionado
--      `cp.dt_cadastro_conta` como último fallback (NOT NULL), mesmo padrão
--      dos itens 9/10.
--
-- Achados que PERMANECEM sem correção nesta query (lacuna de cadastro/dado de
-- origem, mesmo critério dos itens 17/18 — não inventar dado):
--  21. 🔴 `executante_municipio` voltou a falhar em 06/2026 (20 linhas) e
--      07/2026 (43 linhas) — desta vez por PRESTADORES PESSOA FÍSICA sem
--      endereço cadastrado (CPFs distintos do Laboratório Saúde já corrigido
--      no item 17). Detalhe nominal em
--      `10_PROJETOS/envio-dados-tiss-competencia-07-2026/ANEXOS/competencia-
--      0{6,7}-2026/CORRECOES-NECESSARIAS.md`.
--  22. 🔴 Contas com `vl_apresentado=0.00` mas procedimentos ativos de valor
--      real (04/2026: contas 3/4/5 no sentido contrário; 05/2026: conta 380;
--      07/2026: contas 2572/2573/3580) — inconsistência entre o valor
--      cacheado na conta e a soma real dos itens, recorrente mês a mês.
--      Padrão comum: contas ainda em análise (`ie_situacao='1'`). Não
--      corrigido na query — decidir qual valor é a fonte de verdade é decisão
--      de negócio/faturamento, não da query.
--  23. 🔴 Procedimentos duplicados na origem (`sps_conta_medica_proc`, mesmo
--      código/quantidade/valor, múltiplas linhas ativas) — recorrente e
--      crescente mês a mês (05/2026: 3 grupos/1 conta; 06/2026: 9 grupos/6
--      contas; 07/2026: 31 grupos/25 contas, incluindo as mesmas contas de
--      06/2026 ainda não corrigidas). Não é bug da query (cada linha é um
--      `idsps_conta_medica_proc` ativo e distinto) — é lançamento duplicado no
--      faturamento. Vale um levantamento dedicado com a área de faturamento,
--      dado o padrão crescente.
--  24. ✅ RESOLVIDO 2026-09-22 — `cbo_executante` (`cm.cd_cbo`) com códigos que
--      não existem na tabela CBO do schema oficial da ANS — achado na
--      validação XML/XSD real de 04/2026 (só alcançável depois que os erros
--      de CSV pararam de bloquear a validação antes de chegar nessa camada).
--      5 contas afetadas: 18 (cd_cbo='90'→'225285' Médico urologista,
--      confirmado por Johnathan: Dr. Romulo Orlando da Silva é urologista,
--      bate com o exame faturado — US bexiga/próstata/vesículas seminais),
--      88 ('54'→'225320' Médico em radiologia e diagnóstico por imagem), 104
--      ('54'→'225305' Médico citopatologista), 107 ('79'→'225305' Médico
--      citopatologista), 117 ('45'→'225335' Médico patologista clínico /
--      medicina laboratorial) — estes 4 últimos inferidos pelo procedimento
--      faturado (nenhum profissional tem especialidade cadastrada em
--      `profissional_especialidade`), aplicados por decisão de Johnathan.
--      Correção feita via UPDATE direto em `sps_conta_medica.cd_cbo`
--      (dado de cadastro, não bug de query) — não pela query, já que o
--      problema era o valor armazenado na origem. Script com DROP/CREATE de
--      `trg_sps_conta_medica_before_update` (bloqueava por lote fechado) em
--      `10_PROJETOS/envio-dados-tiss-competencia-07-2026/ANEXOS/
--      competencia-04-2026/scripts/`. Validado 2026-09-22: **04/2026 passou
--      em TODAS as validações locais** (CSV + geração de XML + schema
--      oficial XSD da ANS) — primeira competência a chegar nesse ponto.
--      ⚠️ RESSALVA (ver nota 25): essa validação local usa só o XSD, que
--      NÃO checa a regra de negócio 259 do Componente Organizacional
--      (mês/ano da `dataProcessamentoGuia` = mês/ano da competência) — essa
--      regra só é aplicada pelo PTA da ANS de fato. O arquivo gerado nesta
--      etapa já estava tecnicamente inválido por causa dela; corrigido na
--      nota 25.
--      05/06/07-2026 ainda não chegaram nessa camada de validação (têm
--      bloqueios de CSV anteriores) — o mesmo tipo de achado pode aparecer
--      neles quando os bloqueios de CSV forem resolvidos.
-- -----------------------------------------------------------------------------
--  25. ✅ RESOLVIDO 2026-09-22 — ACHADO CRÍTICO: o arquivo real de 04/2026
--      (`4245612026040022.XTE`, gerado por Johnathan com o registro ANS real
--      da Novamed) foi rejeitado por análise externa e confirmado por nós:
--      272 das 279 contas (avisadas em abril, liberadas só em maio) saíam
--      com `dataProcessamentoGuia` de MAIO dentro do arquivo de competência
--      ABRIL — violação direta da regra 259 do Padrão TISS - Componente
--      Organizacional (julho 2026): "Em cada arquivo enviado todos os
--      lançamentos com tipo de registro igual a 'inclusão' devem ter o
--      mês/ano da data de processamento igual ao mês/ano da competência do
--      arquivo. Caso contrário, o arquivo será rejeitado." Verificado no
--      documento oficial (`docs/ans/originais/
--      PadroTISS_ComponenteOrganizacional_202607.pdf`, regras 257-267 e
--      Quadros 6-8) — NÃO foi tomado como verdade só pela análise externa
--      colada pelo usuário; conferido na fonte primária antes de agir.
--
--      Causa raiz: `data_processamento_guia` usava um COALESCE de datas do
--      estado ATUAL da conta (`dt_fim_analise`/`dt_liberacao_protocolo`/
--      `dt_autorizacao`/`dt_cadastro_conta`), sem relação com QUAL dos 3
--      eventos (avisado/liberado/pago) fez a conta entrar nesta competência.
--      O modelo real da ANS (Quadros 6-8): a MESMA guia gera um lançamento
--      de Inclusão NOVO em CADA competência em que sofreu processamento,
--      cada um com sua própria data e valores vigentes NAQUELE momento — não
--      "1 linha com o estado mais atual".
--
--      Correção: CTEs de evento (avisado/liberado/pago) passaram a carregar
--      sua própria `dt_evento`; nova CTE `contas_evento_periodo` escolhe, por
--      conta, o evento de maior prioridade (PAGO > LIBERADO > AVISADO) entre
--      os que ocorreram NESTA competência — decisão do usuário 2026-09-22 de
--      não desdobrar em lançamentos separados quando 2 eventos caem no mesmo
--      mês (mais simples, ainda resolve o bug principal). `dataProcessamentoGuia`
--      passou a ser a data do evento vencedor. Todas as colunas de valor que
--      dependiam do estado "processado/liberado/pago" (`valor_processado`,
--      `valor_glosa_guia`, `valor_pago_guia`, os 6 `valor_total_*_procedimentos`,
--      `data_pagamento`, `quantidade_paga`, `valor_pago_procedimento` a nível
--      de item) passaram a ser condicionadas ao evento vencedor da
--      competência, não mais ao estado atual (`ps.protocolo_pago`) — decisão
--      do usuário 2026-09-22: lançamento AVISADO mostra só valor informado,
--      liberado/pago = 0, mesmo que a conta já tenha avançado de estágio
--      depois (isso vira o lançamento da competência em que aquele evento
--      realmente ocorreu).
--
--      Validado 2026-09-22 contra produção, as 4 competências já geradas:
--      100% das contas de cada arquivo agora têm `dataProcessamentoGuia`
--      dentro do próprio mês de competência (antes: só 3/279 em 04/2026).
--      Population idêntica em todas (279/765/2.183/2.412 contas) — a
--      correção não mudou QUAIS contas entram, só a data/valores de cada
--      lançamento. 04/2026: 218 contas resolvidas como AVISADO, 61 como
--      LIBERADO, 0 como PAGO (nenhuma regressão nos achados de cadastro já
--      conhecidos de 05/06/07-2026 — mesmos erros de antes, nenhum novo).
--
--      🔴 PENDENTE (fora do escopo desta correção, decisão consciente do
--      usuário): quando avisado e liberado ocorrem na MESMA competência, só
--      1 lançamento é emitido (o mais avançado) — o modelo ANS mais fiel
--      geraria 2 lançamentos com `dataProcessamentoGuia` diferentes no mesmo
--      arquivo. Avaliar se isso é aceitável para a operadora ou se precisa
--      de um desdobramento futuro.
-- -----------------------------------------------------------------------------
-- Ajustes 2026-09-22 — auditoria do arquivo REAL gerado com registro ANS
-- verdadeiro (`4245612026040022.XTE`), análise recebida e verificada contra
-- as fontes primárias antes de agir (ver ANEXOS/competencia-04-2026/
-- ANALISE-ACHADOS-XTE-REAL.md para o texto completo, incluindo os trechos
-- exatos dos PDFs/XSD que confirmam cada achado):
--  26. ✅ RESOLVIDO — `dataProtocoloCobranca`/`dataProcessamentoGuia`
--      apareciam ANTES de `dataRealizacao` em 145 e 87 das 279 contas de
--      04/2026 — violação da regra ANS de que o protocolo de cobrança não
--      pode anteceder a realização. Causa raiz: `data_realizacao` usava
--      `cp.dt_cadastro_conta` (data de CADASTRO da conta) como proxy, quando
--      `sps_conta_medica_proc.dt_realizacao` (data real de execução, por
--      item) já existe e cobre 99,6% das contas da Novamed
--      (7.171/7.199, confirmado via MCP MySQL) — nunca tinha sido usada.
--      Corrigido: nova CTE `realizacao_conta` com `MIN(dt_realizacao)` por
--      conta, priorizada sobre a cadeia de fallback antiga. Resultado após
--      reprocessar 04/2026: violações caíram de 145→15 e de 87→15 — os 15
--      remanescentes têm `dt_realizacao` preenchido em TODOS os itens, mas
--      ainda assim posterior ao cadastro do protocolo (contas 138, 146, 147,
--      158, 159, 173, 179, 182, 236, 238, 388, 459, 460, 461, 949 —
--      confirmado via MCP MySQL, ex.: conta 138 com protocolo cadastrado
--      29/04 mas `dt_realizacao`=03/05) — inconsistência de dado-fonte
--      genuína (mesma classe dos achados de contas 3/4/5, 1084, 380 já
--      documentados), não bug de query; não corrigido aqui.
--  27. ✅ RESOLVIDO — `numeroGuia_prestador`/`numeroGuia_operadora` das 5
--      contas com `origemEventoAtencao=5` (Prestador eventual) traziam o
--      número real da guia em vez de zeros — confirmado no PDF oficial
--      (Componente de Conteúdo e Estrutura, nov/2025, campo "Número da guia
--      atribuído pela operadora", identificador ANS 024): "Quando a origem
--      da guia for igual a 4-Reembolso ao beneficiário ou 5-Prestador
--      eventual, o campo deve ser preenchido com
--      '00000000000000000000' (20 zeros)". Corrigido para
--      `numero_guia_operadora` (regra confirmada literalmente) e, por
--      analogia, `numero_guia_prestador` (mesma exigência não encontrada de
--      forma explícita para este campo nos PDFs consultados — única parte
--      desta rodada sem confirmação literal na fonte).
--  28. ✅ RESOLVIDO 2026-09-22 — `tipo_evento_atencao` era um passthrough
--      direto de `cm.ie_tipo_guia_tiss` (domínio interno 831), mas esse
--      domínio usa números DIFERENTES do domínio oficial ANS
--      `dm_tipoEventoMonitoramento` (confirmado no comentário embutido pela
--      própria ANS dentro do XSD real, `tissSimpleTypesMonitoramentoV1_06_00.xsd`:
--      1=Consulta, 2=SP/SADT, 3=Internação, 4=Odontológico, 5=Honorários —
--      enquanto o domínio interno 831 usa 3=SP/SADT, 2/4/5=Internação).
--      278 das 279 contas de 04/2026 (SP/SADT de verdade) estavam sendo
--      declaradas à ANS como "Internação". Crosswalk implementado e
--      confirmado pelo usuário 2026-09-22: 831{1}→ANS{1}, 831{3}→ANS{2},
--      831{2,4,5}→ANS{3}, 831{6}→ANS{4}, 831{7}→ANS{5}, 831{8,9,10,11}
--      (OPME/Quimio/Outras Despesas/Radioterapia, sem correspondência direta
--      no domínio ANS de 5 valores) →ANS{2}, por analogia (anexos do bloco
--      SP/SADT no TISS). Ver ANALISE-ACHADOS-XTE-REAL.md para o texto
--      completo da verificação nas fontes primárias.
--  29. ✅ RESOLVIDO 2026-09-23 — 3 inconsistências financeiras achadas numa
--      3ª análise externa sobre o `.XTE` real de 04/2026 já regenerado com
--      os fixes 25-28. Todas reproduzidas exatamente nos nossos dados e
--      confirmadas na fonte primária (Padrão TISS Componente de Conteúdo e
--      Estrutura, nov/2025, planilha `operadoraParaANS`) antes de corrigir:
--        a) `valor_processado` (campo 051, "= informado − glosa da guia")
--           usava `vl_liberado + vl_glosado`, que na prática reconstrói
--           `vl_apresentado` quase sempre (identidade contábil confirmada:
--           vl_liberado + vl_glosado = vl_apresentado em 7.501/7.512 contas
--           da Novamed, 99,85%) e zerava por completo no AVISADO — 218/279
--           guias de 04/2026 com valor errado. Corrigido para
--           `informado − glosa` (glosa já 0 no AVISADO ⇒ resultado =
--           informado, coerente com "guia apresentada mostra o valor
--           apresentado e só o pago zerado").
--        b) os 6 `valor_total_pago_*` (campos 052-057, semântica de
--           PAGAMENTO real pela regra ANS e pela exigência do campo 059 de
--           bater com a soma do campo 073 do mesmo lançamento) estavam
--           gated `IN ('LIBERADO','PAGO')` usando `vl_total_aprovado`
--           (valor de análise/liberação, não de pagamento), enquanto
--           `valor_pago_guia` e o campo de item já eram gated só `= 'PAGO'`
--           — 61/279 guias de 04/2026 com `valor_total_pago_procedimentos`
--           > 0 e `valor_pago_guia` = 0 ao mesmo tempo. Gating dos 6 campos
--           corrigido para `= 'PAGO'`, igual às colunas que já estavam
--           certas.
--        c) `valor_total_coparticipacao` (campo 084, "deve ser igual à
--           soma do campo 085 dos itens do mesmo lançamento") usava
--           `cp.vl_coparticipacao` — coluna de CABEÇALHO independente dos
--           itens — divergindo da soma real dos itens em 162/279 guias de
--           04/2026. Corrigido para somar os itens de verdade
--           (`tg.vl_coparticipacao_total`, nova coluna agregada na CTE
--           `totais_guia`).
--      Achados à parte na mesma análise, JÁ CONHECIDOS e não retrabalhados
--      aqui: as 15 guias de ordem cronológica residual (dado-fonte, nota
--      26) e os 3 guias com `valor_total_informado` ≠ soma dos itens +
--      2 guias com procedimento repetido na mesma conta (contas 3/4/5 e
--      131/142 — mesma classe de inconsistência de dado-fonte já
--      documentada, não bug de query).
--  30. ✅ RESOLVIDO 2026-09-23 — `cbo_executante` (`cp.cd_cbo`) com o literal
--      `999999` em 9 guias de 04/2026 (contas 100, 362, 427, 429, 439, 459,
--      460, 461, 949), achado numa 4ª análise externa sobre um `.XTE` real
--      já reprocessado com o fix da nota 29 (confirmou os 3 fixes
--      financeiros zerados). Campo 035 do Componente de Conteúdo e
--      Estrutura ANS: "Lançamento com CBO igual a 999999 será rejeitado" —
--      regra absoluta, não condicional. Confirmado nos dados: as 9 contas
--      são todas de laboratórios (Hemolabor, Laboratório Saúde) com
--      `ie_tipo_atendimento_tiss` = 8 ou 23 — o mesmo campo 035 só é
--      OBRIGATÓRIO quando tipo de guia = Consulta/SP-SADT E tipo de
--      atendimento = 4-Consulta E origem ∈ {1,2,3}; como o atendimento não é
--      4-Consulta nesses 9 casos, o campo nem é obrigatório. Corrigido com
--      `NULLIF(cp.cd_cbo, '999999')` — nunca emite o literal proibido; se um
--      caso futuro tiver `cd_cbo='999999'` E o campo for obrigatório, o
--      resultado passa a ser "obrigatório ausente" (honesto), não mais um
--      valor garantidamente rejeitado.
--      Achados à parte na mesma análise, JÁ CONHECIDOS/reconfirmados, não
--      retrabalhados: as mesmas 15 guias de ordem cronológica (nota 26) e os
--      mesmos 3+2 guias de `valor_total_informado`/procedimento repetido
--      (contas 3/4/5 e 131/142, nota 29).
--  31. ✅ RESOLVIDO 2026-09-23 — procedimento repetido na mesma guia
--      (mesma `ie_tabela_tuss`+`cd_procedimento` em mais de 1 linha de
--      `sps_conta_medica_proc`, ambas `status='A'`, valores geralmente
--      diferentes entre si — ex. conta 131, procedimento 40302580: uma linha
--      R$3,48, outra R$16,55). Achado pela primeira vez em 04/2026 (contas
--      131, 142) e crescente em volume nas competências seguintes (05: 3
--      grupos/1 conta; 06: 9 grupos/6 contas; 07: 31 grupos/25 contas). O
--      Padrão TISS proíbe repetição do mesmo procedimento/item da mesma
--      tabela dentro do mesmo lançamento. Decisão do usuário 2026-09-23:
--      CONSOLIDAR em 1 linha por conta+tabela+procedimento, somando
--      quantidade e valores (informado, pago, coparticipação) — não é mais
--      tratado como pendência de cadastro/faturamento, é resolvido pela
--      query. Implementado com a CTE `itens_calculados` (calcula
--      quantidade/valor pago por item ORIGINAL, cada um com seu próprio
--      `vl_unitario` — não dá pra somar unitários e recalcular depois) +
--      `itens` (agrupa por conta+tabela+procedimento, somando os resultados
--      já calculados). `totais_guia` não precisou mudar — soma por
--      classificação é associativa, dá o mesmo resultado agrupado ou não.
--  32. ✅ RESOLVIDO 2026-09-23 — 4ª análise externa sobre o `.XTE` real de
--      04/2026 (já com os fixes 25-31 aplicados) trouxe 2 achados até então
--      "já conhecidos, sem correção de query" (notas 26 e 29-alínea) que,
--      investigados de novo, tinham causa raiz corrigível:
--        a) `valor_total_informado` ≠ soma dos itens (contas 3, 4, 5) — 9
--           itens Novamed-wide (só essas 3 contas) com `vl_total_apresentado
--           = 0` e `vl_unitario > 0`, sendo que a mesma linha já tem
--           `vl_total_aprovado = vl_unitario × qt_realizada` corretamente
--           preenchido. `itens_calculados.vl_total_apresentado` passou a usar
--           `COALESCE(NULLIF(vl_total_apresentado, 0), vl_unitario ×
--           qt_realizada)` — mesma fórmula que o sistema já usa para
--           `vl_total_aprovado`, não inventa valor. Fecha 100% do gap nas
--           contas 3 e 5; conta 4 fecha só R$1.200 dos R$2.000 (R$800
--           residuais sem explicação nos dados, seguem como pendência de
--           cadastro/faturamento).
--        b) 15 guias com `dataProtocoloCobranca` anterior à `dataRealizacao`
--           (contas 138, 146, 147, 158, 159, 173, 179, 182, 236, 238, 388,
--           459, 460, 461, 949 de 04/2026). Causa raiz: `pcm.dt_insert`
--           (data do LOTE em `sps_protocolo_conta_medica`) é anterior à
--           própria criação da conta médica nessas guias — o lote é
--           cadastrado no sistema antes de a conta existir. `data_protocolo_
--           cobranca` trocado de `ps.dt_cadastro_protocolo` (= `pcm.dt_
--           insert`, o lote) para `cp.dt_cadastro_conta` (= `sps_conta_
--           medica.dt_insert`, a própria conta — bate no mesmo dia com
--           `dt_realizacao` real nas 15 guias). Decisão do usuário
--           2026-09-23: mudar SÓ este campo, sem tocar no evento AVISADO/
--           competência (nota 25, continua em `pcm.dt_insert`) — evita
--           reabrir a lógica de atribuição de competência já validada em
--           21/09/2026. Validado Novamed-wide: reduz violações cronológicas
--           residuais em 05/2026 (26→1) e 06/2026 (73→5) sem piorar nenhuma
--           competência (07/2026 igual, 08-10/2026 ainda não geradas mas já
--           conferidas: mesmo padrão de pendência genuína de dado-fonte,
--           não corrigível pelo fallback de conta — fica documentado).
--  33. ✅ SEM MUDANÇA DE QUERY 2026-09-23 — 5ª análise externa sobre o `.XTE`
--      real de 04/2026 (já com a nota 32) confirmou os fixes anteriores
--      (0 CBO 999999, 0 `dataProtocoloCobranca<dataRealizacao`, 279/279
--      `valorProcessado`/coparticipação corretos) e trouxe 3 pontos:
--        a) CNES `9999999` em 259/279 registros — Johnathan corrigiu
--           `pessoa_juridica.cd_cnes` em produção para os 4 CNPJs afetados
--           (Saúde Instituto de Análises Clínicas, Hemolabor, Centro de
--           Diagnósticos Portugal, Yaspers & Yaspers) usando os códigos reais
--           do CNES/DATASUS indicados pela análise. A query já lia
--           `pj.cd_cnes` diretamente (sem hardcode) — só precisou reprocessar.
--           04/2026: 259→0 ocorrências de `9999999`.
--        b) `identificacaoReembolso...000004` (conta 4) com `valorTotalInfor-
--           mado` R$800,00 maior que a soma dos itens (dos R$2.000 originais
--           da nota 32, R$1.200 já tinham sido explicados pelo fallback de
--           `vl_unitario`). Investigação aprofundada: a conta 4 é quase
--           idêntica à conta 3 (mesmo beneficiário 43, guias sequenciais
--           10074/10075, cadastradas com 1 segundo de diferença, mesmos 3
--           itens acessórios de R$200/R$200/R$800) — mas o item PRINCIPAL
--           (procedimento 34108) da conta 4 foi lançado em R$22.732,02 contra
--           R$23.532,03 da conta 3 (diferença de R$800,01), enquanto os
--           cabeçalhos (`vl_apresentado`) das duas contas ficaram praticamente
--           iguais (R$24.732,02 vs R$24.732,03). Forte indício de erro de
--           digitação no item principal da conta 4 — não corrigido via query
--           (inventaria um valor), fica pendência de faturamento.
--        c) Achado novo (sem correção de rejeição confirmada pela ANS): 15
--           guias com `dataProcessamentoGuia < dataRealizacao` (as mesmas 15
--           de sempre — evento AVISADO de abril, realização em maio) e 186
--           guias com `dataProcessamentoGuia < dataProtocoloCobranca` — este
--           último é consequência direta da nota 32 (campo 032 passou a usar
--           `cp.dt_cadastro_conta`, tipicamente posterior ao cadastro do LOTE
--           que dispara o evento AVISADO). Nem eu nem a análise externa
--           encontramos regra ANS explícita exigindo essa ordem entre
--           `dataProcessamentoGuia` e `dataProtocoloCobranca`/`dataRealizacao`
--           (a única regra confirmada, 259, exige mês/ano de
--           `dataProcessamentoGuia` = competência do arquivo, que os 279/279
--           atendem) — tratado como observação de qualidade de dado, não
--           bloqueio, não corrigido via query sem confirmação de regra.
--      Reprocessadas as 4 competências: 04/2026 continua passando em TUDO
--      (`exit 0`); 05/06/07 sem regressão (mesmos erros de cadastro já
--      documentados, contagens idênticas às da nota 32); CNES 9999999 ainda
--      presente em 05/06/07 (375/1.281/2.016 linhas) — prestadores diferentes
--      dos 4 já corrigidos, mesma classe de pendência de cadastro.
--  34. ✅ RESOLVIDO 2026-09-23 (decisão explícita do usuário: "equalizar
--      somente no CSV") — `valorTotalInformado`/`valorProcessado` passaram a
--      usar `SUM(itens.vl_total_apresentado)` (CTE `totais_informado_guia`)
--      em vez de `cp.vl_apresentado` (cabeçalho da conta). Resolve por
--      construção, para qualquer conta/competência, a divergência
--      cabeçalho×itens documentada desde 21/09/2026 (contas 3/4/5) — não é
--      mais um fallback especial por conta, é a fonte de verdade do campo
--      passando a ser a mesma soma que os itens do arquivo já reportam.
--      Nenhum dado foi alterado em produção — `cp.vl_apresentado` (usado só
--      como COALESCE de segurança) continua divergente na base viva; a causa
--      (indício de erro de digitação no item principal da conta 4, nota
--      33-b) continua pendência de faturamento, sem relação com este ajuste
--      de apresentação do arquivo.
--
--  Achado 33-c (datas) — NÃO IMPLEMENTADO por decisão técnica: o usuário
--  pediu para ajustar `dataProcessamentoGuia` das 186+15 guias para datas
--  "aleatórias em dias úteis" que satisfaçam a ordem cronológica. Recusado —
--  seria inventar data de evento que não ocorreu, para um arquivo de
--  declaração a um órgão regulador (ANS), o que a própria regra do
--  repositório proíbe ("não inventar informações"). Investigação confirmou
--  que a ordem também não pode ser corrigida usando datas REAIS já existentes
--  (ex. `GREATEST` entre as 3 datas) sem violar a regra 259 (mês/ano de
--  `dataProcessamentoGuia` = competência do arquivo, essa sim confirmada
--  explicitamente): nessas guias o protocolo/realização real caem em maio,
--  então qualquer ajuste honesto da ordem empurraria `dataProcessamentoGuia`
--  para fora de 04/2026. Única correção honesta possível é reclassificar
--  essas guias para a competência em que os eventos realmente ocorreram
--  (opção C, documentada em PLANO-CORRECAO-XTE-0022-datas-valores.md) —
--  decisão de negócio de maior impacto, aguardando confirmação explícita do
--  usuário antes de reabrir a lógica de competência (nota 25).
--
--  35. ✅ RESOLVIDO 2026-09-23 — decisão explícita do usuário ("reclassificar
--      as 15 contas para o mês seguinte", depois ampliada para "aplicar a
--      regra geral nas 4 competências" ao descobrir que as 15 eram só uma
--      fração de um padrão sistemático de 827 contas). Ver CTE
--      `contas_avisadas_periodo` acima (evento AVISADO) para o detalhe
--      completo: `GREATEST(pcm.dt_insert, cm.dt_insert)` substitui
--      `pcm.dt_insert` sozinho, usando só datas REAIS já existentes (nunca
--      fabrica nada), e reclassifica automaticamente qualquer conta cujo
--      lote tenha sido pré-criado antes dela existir para a competência em
--      que ela de fato foi cadastrada. Resolve por completo, como efeito
--      colateral, os achados das notas 32 (15 guias) e 33 (186 guias) —
--      `dataProcessamentoGuia` passa a coincidir com
--      `dataProtocoloCobranca`/`dataRealizacao` nessas contas, porque as
--      três datas passam a vir da mesma fonte real (cadastro da conta).
--      Efeito Novamed-wide medido antes de aplicar: 184 contas saem de
--      04/2026 e entram em 05/2026; 7 de 05→06; 377 de 06→07; 259 de
--      07→08 (08/2026 ainda não gerada nesta rodada). Reprocessadas as 4
--      competências já geradas — ver DECISOES.md para os números finais de
--      cada uma e a validação completa (CSV+XML+XSD) após a mudança.
--      Pendência separada registrada: `query_diops_dados_eventos_v2.sql`
--      (exportação contábil de eventos) ainda usa só `pcm.dt_insert` para
--      `data_aviso` — não foi alterada nesta rodada (fora do escopo desta
--      query/projeto) — avaliar depois se deveria receber o mesmo ajuste
--      para as duas exportações continuarem sincronizadas (mesmo cuidado já
--      registrado na nota 14, 21/09/2026).
--  36. ✅ RESOLVIDO 2026-09-23 — achado numa 9ª análise externa sobre o `.XTE`
--      real de 04/2026 (já com a nota 35 aplicada): campo `formas_remuneracao`
--      (122/128, XML `formasRemuneracao`) estava hardcoded NULL desde a
--      criação da query, nunca implementado. Regra ANS: obrigatório para
--      origem 1/2/3, exceto rede própria (3) de mesmo CNPJ da operadora; não
--      preencher para 4/5. Verificado Novamed-wide: nenhum registro de
--      origem 3 na base viva é o próprio CNPJ da Novamed (`59545401000170`)
--      — exceção não se aplica hoje. Nenhuma tabela do schema `producao`
--      representa o conceito TISS de modelo de remuneração por prestador
--      (toda a base de faturamento médico é 100% por procedimento
--      individual, sem infraestrutura de pacote/capitation/DRG em nenhum
--      lugar do sistema) — decisão do usuário 2026-09-23 (pergunta
--      explícita, mesmo critério da recusa de fabricar dado das notas 33/34):
--      declarar código `01` (Pós-pagamento por Procedimento) para os
--      registros elegíveis, com valor = `valorTotalInformado` da própria
--      guia (mesma fonte da coluna `valor_total_informado`, nota 34) — só 1
--      modelo por guia, soma fecha 100% por definição. Ver
--      PLANO-CORRECAO-MODELO-REMUNERACAO.md (ANEXOS/competencia-04-2026) para
--      o levantamento completo e DECISOES.md para o resultado do
--      reprocessamento das 4 competências.
--  37. ✅ RESOLVIDO 2026-09-24 — pedido explícito do usuário: "qualquer dado de
--      entidade tem que ser somente quando ativo" (`status='A'`), não só
--      conta/protocolo/log/procedimento-da-conta (já filtrados desde sempre).
--      Achado real ao investigar antes de corrigir (não presumido): 2 tabelas
--      sem filtro de `status` alimentavam contas já exportadas —
--      `sps_beneficiario`/`pessoa_fisica`/`sps_produto` (CTE
--      `beneficiario_dados`) e `sps_prestador`/`pessoa_juridica`/`pessoa_fisica`
--      (CTE `prestador_dados`), além de `logradouro`/`municipio` nas 3 CTEs de
--      endereço e `procedimento` nas CTEs `totais_guia`/`itens_calculados`.
--      Confirmado via `information_schema.columns` que todas essas tabelas têm
--      coluna `status` ('A'/'I', mesmo domínio de sempre) e via consulta direta
--      em produção (idestabelecimento=19) que 2 contas médicas REAIS já
--      exportadas (2038 em 06/2026, 4741 em 07/2026) usavam dado de um
--      `pessoa_fisica` com `status='I'` vinculado a um beneficiário `status='A'`
--      — achado concreto, não hipotético. Filtro adicionado em cada CTE (ver
--      nota nos comentários de `beneficiario_dados`, `prestador_dados` e das 3
--      CTEs de endereço): quando a entidade referenciada está inativa, o dado
--      dela some da exportação (fica NULL) em vez de vazar — a conta médica em
--      si continua entrando pela mesma regra de sempre (evento na competência),
--      não é removida do arquivo; a lacuna de beneficiário/prestador passa a
--      ser capturada pela auditoria padrão de CORRECOES-NECESSARIAS.md, mesmo
--      tratamento já dado a endereço/CNS ausente — nenhum dado fabricado.
--      Reprocessadas as 3 competências em aberto (05, 06, 07/2026) — ver
--      DECISOES.md para o resultado (contas/linhas afetadas por competência).
--
--  38. ✅ PARCIALMENTE RESOLVIDO 2026-09-24 — 11ª análise externa sobre o
--      `.XTE` real de 05/2026 (arquivo de teste, lote 0023, gerado antes
--      desta rodada). Reproduzido cada achado objetivo em produção
--      (somente leitura, idestabelecimento=19, competência=202605) antes de
--      corrigir, conforme o processo padrão:
--      a) ✅ RESOLVIDO — `executante_cnes` sem zero à esquerda (conta 183,
--         CNES `500356`→`0500356`) — ver correção em `executante_cnes`
--         acima. Causa raiz: `pessoa_juridica.cd_cnes` é `INT`, descarta
--         zero à esquerda; `LPAD` restaura sem inventar dígito. Mais 2
--         prestadores Novamed-wide no mesmo caso (410691, 880418).
--      b) ✅ RESOLVIDO — `data_pagamento` ausente com `valorPagoGuia`>0
--         (conta 1035, R$11.067,88 pago sem data) — ver correção em
--         `data_pagamento` acima. Causa raiz: `cp.dt_pagamento`
--         (`cm.dt_pagamento`, coluna crua) não é atualizada de forma
--         confiável; o log confirma o pagamento em 27/05/2026 18:38:14.
--         Trocado para `cp.dt_evento_lancamento` (mesma fonte já usada para
--         `tipo_evento_lancamento='PAGO'`).
--      c) ✅ SEM CORREÇÃO DE QUERY — protocolo (26/05) anterior à realização
--         (27/05) na mesma conta 1035: já é o mesmo padrão de resíduo
--         cronológico documentado na nota 35/PENDENCIAS-CONFIRMACAO (causa
--         de dado-fonte, não de query — não fabricar data).
--      d) ✅ CONFIRMADO SEM AÇÃO — 16 guias com `dataProcessamentoGuia <
--         dataProtocoloCobranca` (inclui a guia 949 com `< dataRealizacao`
--         também): mesma contagem exata do resíduo já documentado
--         (nota 35/PENDENCIAS-CONFIRMACAO), sem regra ANS explícita
--         exigindo essa ordem — mantido como estava.
--      e) 🔴 CONFIRMADO, PENDÊNCIA DE DADO-FONTE (não é bug de query) —
--         `tipo_consulta` ausente em 225/249 guias elegíveis de 05/2026
--         (222/246 Consultas + 3/4 SP/SADT com `tipo_atendimento=04`,
--         reproduzido exatamente). Já é passthrough direto de
--         `cm.ie_tipo_consulta` (sem domínio a mapear — a coluna já usa o
--         mesmo código 1/2 do XSD `dm_tipoConsulta`, confirmado no schema).
--         Investigação Novamed-wide (todas as contas tipo Consulta, não só
--         05/2026) mostra um padrão temporal real: 2026-05 tem 224/246
--         (91%) NULL, 2026-06 cai para 109/633 (17%), 2026-07 em diante é
--         0% NULL — o campo simplesmente não era preenchido de forma
--         consistente no cadastro em maio (a origem do problema é anterior
--         ao TISS, é a rotina de atendimento/faturamento não capturando o
--         dado), sem qualquer sinal de bug de query. Não corrigível sem
--         inventar dado — registrado como pendência de negócio/cadastro em
--         PENDENCIAS-CONFIRMACAO.md, não implementado.
--      f) ✅ CONFIRMADO SEM AÇÃO — `formaEnvio=4` fixo para as 760 guias:
--         mesmo achado já registrado e aceito como risco (ver nota acima
--         sobre `formaEnvio`, PENDENCIAS-CONFIRMACAO.md), não revisitado
--         nesta rodada por decisão anterior do usuário.
--      Reprocessada e revalidada (CSV+XML+XSD) a competência 05/2026 após
--      os fixes (a)/(b) — ver DECISOES.md para o resultado. Escopo desta
--      rodada limitado a 05/2026 por pedido explícito do usuário; os fixes
--      (a)/(b) são de query (afetam qualquer competência com o mesmo padrão
--      de dado) — 06/07/2026 ainda não reprocessadas com esta correção.
--  39. ✅ RESOLVIDO 2026-09-24 — decisão explícita do usuário sobre o achado
--      38-c (conta 1035, protocolo 26/05 anterior à realização 27/05):
--      explicou a causa raiz de NEGÓCIO por trás do padrão (não apenas
--      confirmou que ele existe) — em atendimento PARTICULAR, a equipe
--      cadastra a conta médica e o protocolo ANTES de o paciente
--      efetivamente comparecer à clínica (o protocolo é criado para AGENDAR
--      o atendimento, que só ocorre depois) — o inverso do fluxo normal
--      (paciente atende, a conta é protocolada depois), que é a premissa por
--      trás da regra ANS do campo 032. Instrução explícita: "quando a data
--      de realização for maior que a data do protocolo, assumir a data do
--      protocolo". Implementado com `LEAST()` entre a expressão já existente
--      de `data_realizacao` e a mesma `COALESCE` já usada em
--      `data_protocolo_cobranca` (ver campo acima) — usa só datas REAIS já
--      presentes no mesmo registro (não fabrica nada, mesmo critério das
--      notas 32/35/38); no caso normal (realização <= protocolo, >99% dos
--      casos), o resultado é idêntico a antes; só quando a realização cai
--      depois do protocolo, a data declarada passa a ser a do protocolo.
--      Resolve por construção o resíduo cronológico documentado desde a nota
--      35 (16+1 guias em 05/2026, 39+1 em 06/2026, 4 em 07/2026) — não é uma
--      correção pontual da conta 1035, é uma regra geral aplicada a qualquer
--      guia com esse padrão, em qualquer competência. Ver DECISOES.md para o
--      resultado do reprocessamento das competências em aberto.
--  40. ✅ RESOLVIDO 2026-09-24 — decisão explícita do usuário sobre o achado
--      38-e (225 guias de 05/2026 sem `tipo_consulta`, gap real de cadastro
--      em maio/2026, sem crosswalk pendente e sem bug de query): quando a
--      guia é do tipo CONSULTA (`cp.ie_tipo_guia_tiss = '1'`) e
--      `ie_tipo_consulta` vier vazio, assumir o código `1` (Primeira
--      Consulta). Verificado antes de implementar: XSD real
--      (`tissSimpleTypesMonitoramentoV1_06_00.xsd`, `dm_tipoConsulta`) confirma
--      1=Primeira/2=Seguimento/3=Pré-Natal/4=Por encaminhamento — o código
--      `1` é o valor pedido pelo usuário, não uma suposição da IA. Aplicado
--      só a guias de Consulta — os 3 SP/SADT com `tipo_atendimento='04'`
--      também citados na nota 38-e não são "tipo de guia Consulta" e ficam de
--      fora do escopo desta decisão (pedido literal do usuário), continuam
--      sem `tipo_consulta`. Quando o dado já vem preenchido, para qualquer
--      guia, o valor original é mantido sem alteração — só cobre a ausência.
--  41. ✅ RESOLVIDO 2026-09-24 — pedido explícito do usuário: endereço de
--      prestador PF (`prestador_endereco_pf`) passou a priorizar o
--      complemento marcado `ie_principal='S'` em vez de restringir a
--      `ie_tipo_complemento=1` (Residencial). Motivo real: 2 prestadores da
--      Novamed (Daniel Portilho De Melo, Paulo Estefano Germano) tiveram o
--      cadastro corrigido em produção só como tipo Comercial (2), que a
--      regra antiga ignorava por completo. Verificado Novamed-wide antes de
--      trocar (15 prestadores PF ativos): a troca resolveria os 2 citados,
--      mas quebraria 1 (Julio Eduardo Ferro, idsps_prestador 67 — sem
--      movimento em 04-07/2026 — cujo endereço principal não tem CEP,
--      só o residencial secundário tem). Implementado com fallback (nunca
--      fabrica endereço): prioriza o complemento principal, mas só entre os
--      que resolvem a um município real; sem resolução no principal, cai
--      para o complemento ativo mais recente que resolver, de qualquer tipo.
--      Ver DECISOES.md (10ª+ rodada) para o resultado do reprocessamento de
--      06/2026 e a comparação antes/depois Novamed-wide.
--  42. ✅ RESOLVIDO 2026-09-25 — pedido explícito do usuário: excluir da
--      exportação qualquer conta médica cujo beneficiário (`sps_beneficiario.
--      ie_ADM='S'`) ou o contrato do beneficiário (`sps_contrato.ie_ADM='S'`)
--      seja administrado por uma administradora de benefícios — não
--      relacionado ao domínio 11. Só entram no arquivo contas com
--      `ie_ADM IS NULL OU = 'N'` nas duas tabelas (default do schema é 'N').
--      Implementado como filtro de POPULAÇÃO (a conta não aparece no
--      arquivo, diferente do padrão da nota 37 que mantém a conta e só
--      zera os campos do beneficiário) — `contas_periodo` ganhou 2 INNER
--      JOINs (`sps_beneficiario`/`sps_contrato` via `sb_adm`/`sc_adm`, FKs
--      NOT NULL, join seguro) e 2 condições no WHERE. Levantamento
--      Novamed-wide (`idestabelecimento=19`, todas as contas ativas,
--      histórico completo) antes de implementar: 23 de 7.521 contas médicas
--      seriam excluídas (18 por beneficiário ADM, 23 por contrato ADM, com
--      sobreposição — união = 23). **Ainda NÃO reprocessado nenhum CSV já
--      gerado (04-07/2026)** — pedido explícito do usuário foi só ajustar a
--      query; ele está validando as informações junto ao setor antes de
--      reprocessar. Ver DECISOES.md (rodada de 2026-09-25) para o
--      detalhamento e o mesmo ajuste replicado em
--      `query_diops_dados_eventos_v2.sql` (exportação contábil de eventos,
--      projeto `exportacao-contabilidade-novamed-integra`).
--  43. ✅ RESOLVIDO 2026-09-25 — 14ª análise externa (06/2026): 23 guias com
--      `valorPagoGuia` ≠ soma das 6 categorias de pagamento
--      (`valorTotalPago*`). Causa raiz: `procedimento.ie_classificacao IS
--      NULL` para `idprocedimento` 34107 ("kit EPI UTI") e 34108 ("Material
--      Hospitalar") — únicos 2 códigos assim em toda a base Novamed
--      (confirmado via agregação Novamed-wide). Nenhum `WHEN` do `CASE` de
--      `totais_guia` cobre `NULL`, então o valor pago desses itens não
--      entrava em nenhum dos 6 buckets de categoria, mas continuava no total
--      item a item (`valor_pago_procedimento`, sem filtro de classificação,
--      fonte de `valorPagoGuia`) — violando a regra ANS de que os dois
--      fechamentos (soma dos itens E soma das categorias) devem bater ao
--      mesmo tempo. Decisão explícita de Johnathan (pergunta feita antes de
--      implementar, mesmo critério das notas 30/40): mapear os 2 códigos
--      para categoria `4` (Materiais e OPME) só nesta query, via
--      `COALESCE(p.ie_classificacao, CASE WHEN p.idprocedimento IN (34107,
--      34108) THEN '4' END)` nos 6 buckets — os próprios nomes dos
--      procedimentos confirmam a categoria; nenhum dado alterado em
--      produção (`procedimento.ie_classificacao` continua NULL na base
--      viva). `ie_tabela_tuss` desses 2 códigos é `'00'` (≠ '19'), então
--      caem em Materiais, não em OPME. Ver DECISOES.md (14ª rodada) e
--      `query_select_exportacao_csv_tiss` para o levantamento completo e o
--      resultado do reprocessamento das competências.
-- =============================================================================
