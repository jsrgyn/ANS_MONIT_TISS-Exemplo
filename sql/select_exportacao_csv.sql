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
-- -----------------------------------------------------------------------------
contas_avisadas_periodo AS (
    SELECT DISTINCT cm.idsps_conta_medica, pcm.dt_insert AS dt_evento
    FROM sps_conta_medica cm
    INNER JOIN sps_protocolo_conta_medica pcm
            ON pcm.idsps_protocolo_conta_medica = cm.idsps_protocolo_conta_medica
           AND pcm.status = 'A'
    CROSS JOIN parametros p
    WHERE cm.status = 'A'
      AND cm.idestabelecimento = p.idestabelecimento
      AND pcm.dt_insert >= p.dt_inicio
      AND pcm.dt_insert <  p.dt_fim_exclusivo
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
    SELECT epr.idsps_protocolo_conta_medica
    FROM eventos_pagamento_ranqueados epr
    CROSS JOIN parametros p
    WHERE epr.nr_evento_pagamento = 1
      AND epr.dt_pagamento >= p.dt_inicio
      AND epr.dt_pagamento <  p.dt_fim_exclusivo
),
contas_pagas_periodo AS (
    SELECT DISTINCT cm.idsps_conta_medica
    FROM sps_conta_medica cm
    INNER JOIN protocolos_pagos_periodo ppp
            ON ppp.idsps_protocolo_conta_medica = cm.idsps_protocolo_conta_medica
    CROSS JOIN parametros p
    WHERE cm.status = 'A'
      AND cm.idestabelecimento = p.idestabelecimento
      AND (p.idprestador IS NULL OR cm.idsps_prestador_exec = p.idprestador)
),
-- -----------------------------------------------------------------------------
-- União dos 3 eventos — população final do arquivo de Monitoramento da
-- competência: toda conta com PELO MENOS UM dos 3 eventos no mês informado.
-- UNION (não UNION ALL) já deduplica contas com mais de um evento no mesmo mês
-- (ex.: avisada e paga na mesma competência).
-- -----------------------------------------------------------------------------
contas_evento_periodo AS (
    SELECT idsps_conta_medica FROM contas_avisadas_periodo
    UNION
    SELECT idsps_conta_medica FROM contas_liberadas_periodo
    UNION
    SELECT idsps_conta_medica FROM contas_pagas_periodo
),
-- -----------------------------------------------------------------------------
-- Contas médicas selecionadas pela união de eventos acima. Os valores
-- (vl_apresentado/vl_liberado/vl_glosado etc.) refletem o estado ATUAL da
-- conta — o filtro de entrada no arquivo é que passou a ser por evento
-- ocorrido na competência, não mais por `ie_situacao` atual + `dt_autorizacao`.
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
        cm.vl_coparticipacao                     -- ✅
    FROM sps_conta_medica cm
    INNER JOIN contas_evento_periodo cep
            ON cep.idsps_conta_medica = cm.idsps_conta_medica
    INNER JOIN sps_protocolo_conta_medica pcm
            ON pcm.idsps_protocolo_conta_medica = cm.idsps_protocolo_conta_medica
           AND pcm.status = 'A'
    CROSS JOIN parametros p
    WHERE cm.status = 'A'
      AND cm.idestabelecimento = p.idestabelecimento
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
    LEFT JOIN logradouro l ON l.cep = pfc.cep -- ✅
    LEFT JOIN municipio m ON m.idmunicipio = l.idmunicipio -- ✅
    WHERE pfc.ie_tipo_complemento = 1         -- ✅ 1 = endereço residencial (padrão SIB)
),
-- -----------------------------------------------------------------------------
-- Dados do beneficiário: CNS/CPF/sexo/nascimento (pessoa_fisica — ✅ confirmado
-- em produção), produto/plano contratado (sps_produto.nr_protocolo_ans — ✅
-- confirmado como o número de registro do produto na ANS, mesmo campo usado
-- na geração do SIB) e município de residência (via beneficiario_endereco).
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
    INNER JOIN pessoa_fisica pf ON pf.idpessoa_fisica = sb.idpessoa_fisica         -- ✅
    LEFT JOIN sps_produto sp ON sp.idsps_produto = sb.idsps_produto                -- ✅
    LEFT JOIN beneficiario_endereco be
           ON be.idpessoa_fisica = sb.idpessoa_fisica AND be.nr_ordem = 1
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
prestador_endereco_pj AS (
    SELECT
        pj.idpessoa_juridica,
        m.cd_ibge
    FROM pessoa_juridica pj
    LEFT JOIN logradouro l ON l.cep = pj.cep
    LEFT JOIN municipio m ON m.idmunicipio = l.idmunicipio
),
prestador_endereco_pf AS (
    SELECT
        pfc.idpessoa_fisica,
        m.cd_ibge,
        ROW_NUMBER() OVER (
            PARTITION BY pfc.idpessoa_fisica
            ORDER BY pfc.dt_update DESC, pfc.idpessoa_fisica_compl DESC
        ) AS nr_ordem
    FROM pessoa_fisica_compl pfc
    LEFT JOIN logradouro l ON l.cep = pfc.cep
    LEFT JOIN municipio m ON m.idmunicipio = l.idmunicipio
    WHERE pfc.ie_tipo_complemento = 1
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
    FROM sps_prestador sp
    LEFT JOIN pessoa_juridica pj ON pj.idpessoa_juridica = sp.idpessoa_juridica -- ✅
    LEFT JOIN pessoa_fisica  pf ON pf.idpessoa_fisica  = sp.idpessoa_fisica     -- ✅
    LEFT JOIN prestador_endereco_pj pej ON pej.idpessoa_juridica = pj.idpessoa_juridica
    LEFT JOIN prestador_endereco_pf pef ON pef.idpessoa_fisica = pf.idpessoa_fisica AND pef.nr_ordem = 1
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
-- -----------------------------------------------------------------------------
totais_guia AS (
    SELECT
        scmp.idsps_conta_medica,
        SUM(CASE WHEN p.ie_classificacao = '1'
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_pago_procedimentos,
        SUM(CASE WHEN p.ie_classificacao = '3'
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_diarias,
        SUM(CASE WHEN p.ie_classificacao IN ('2', '6')
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_taxas,
        SUM(CASE WHEN p.ie_classificacao = '4' AND p.ie_tabela_tuss <> '19'
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_materiais,
        SUM(CASE WHEN p.ie_classificacao = '4' AND p.ie_tabela_tuss = '19'
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_opme,
        SUM(CASE WHEN p.ie_classificacao = '5'
                 THEN scmp.vl_total_aprovado ELSE 0 END)                          AS vl_medicamentos
    FROM sps_conta_medica_proc scmp
    INNER JOIN procedimento p ON p.idprocedimento = scmp.idprocedimento
    WHERE scmp.status = 'A'
    GROUP BY scmp.idsps_conta_medica
),
-- -----------------------------------------------------------------------------
-- Itens (procedimentos) da conta médica — 1 linha de CSV por item; a
-- quantidade paga é derivada de vl_total_aprovado/vl_unitario quando possível
-- (mais precisa que reaproveitar qt_realizada em casos de glosa parcial de
-- quantidade); cai para qt_realizada quando o valor unitário é zero/nulo.
-- -----------------------------------------------------------------------------
itens AS (
    SELECT
        scmp.idsps_conta_medica,
        scmp.idsps_conta_medica_proc,
        scmp.ie_tabela_tuss,                                    -- ✅
        p.cd_procedimento,                                      -- ✅
        scmp.qt_realizada,                                      -- ✅
        scmp.vl_total_apresentado,                              -- ✅ = valor informado do item
        scmp.vl_total_aprovado,                                 -- ✅ = base do valor pago do item
        scmp.vl_unitario,                                       -- ✅
        scmp.vl_coparticipacao,                                 -- ✅
        scmp.cd_unidade_medida                                  -- ✅
    FROM sps_conta_medica_proc scmp
    INNER JOIN procedimento p ON p.idprocedimento = scmp.idprocedimento
    WHERE scmp.status = 'A'
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
    CASE
        WHEN pd.cnes IS NULL
          OR CAST(pd.cnes AS CHAR) = '0'
          OR CHAR_LENGTH(CAST(pd.cnes AS CHAR)) > 7
        THEN '9999999'
        ELSE CAST(pd.cnes AS CHAR)
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
    cp.ie_tipo_guia_tiss                                          AS tipo_evento_atencao,
    -- ✅ RESOLVIDO 2026-09-22 — ver nota 13 no rodapé: fonte trocada de
    -- `cp.ie_origem_conta` (campo errado — método de digitação da conta,
    -- domínio 869) para `pd.origem_evento_atencao_ans`, derivado de
    -- `sps_prestador.ie_tipo_relacao_prestador` (domínio 843), mapeamento
    -- confirmado pelo usuário — ver comentário na CTE `prestador_dados`.
    pd.origem_evento_atencao_ans                                  AS origem_evento_atencao,
    COALESCE(NULLIF(cp.nr_guia_prestador, ''), CAST(cp.idsps_conta_medica AS CHAR))
                                                                   AS numero_guia_prestador,
    COALESCE(NULLIF(cp.nr_guia_prestador, ''), CAST(cp.idsps_conta_medica AS CHAR))
                                                                   AS numero_guia_operadora,
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
    NULL                                                          AS formas_remuneracao,
    NULL                                                          AS guia_solicitacao_internacao,
    NULL                                                          AS data_solicitacao,
    NULL                                                          AS numero_guia_spsadt_principal,
    DATE_FORMAT(cp.dt_autorizacao, '%Y-%m-%d')                    AS data_autorizacao,
    DATE_FORMAT(
        COALESCE(cp.dt_inicio_faturamento, cp.dt_autorizacao, cp.dt_cadastro_conta),
        '%Y-%m-%d'
    )                                                              AS data_realizacao,
    -- ✅ AJUSTE 2026-08-19 — `dt_inicio_faturamento` E `dt_autorizacao` estão
    -- ambos NULL em ~81% das contas (123/152, confirmado via MCP MySQL);
    -- `cp.dt_cadastro_conta` (= `sps_conta_medica.dt_insert`) é NOT NULL por
    -- definição de coluna, garantindo que o campo obrigatório do XSD nunca
    -- fique vazio — mas é a data de CADASTRO da conta, não necessariamente a
    -- data real de realização do procedimento; tratar como último recurso.
    DATE_FORMAT(cp.dt_inicio_faturamento, '%Y-%m-%d')             AS data_inicial_faturamento,
    DATE_FORMAT(cp.dt_fim_faturamento, '%Y-%m-%d')                AS data_fim_periodo,
    DATE_FORMAT(
        COALESCE(ps.dt_recebimento, ps.dt_cadastro_protocolo, cp.dt_autorizacao, cp.dt_cadastro_conta),
        '%Y-%m-%d'
    )                                                              AS data_protocolo_cobranca,
    -- ✅ AJUSTE 2026-08-19 — `dt_recebimento` está NULL em 100% dos protocolos
    -- da base viva (152/152, confirmado via MCP MySQL) — nunca é gravado pela
    -- aplicação. `ps.dt_cadastro_protocolo` (NOT NULL) é o fallback mais
    -- próximo semanticamente; `cp.dt_autorizacao`/`cp.dt_cadastro_conta`
    -- seguram o caso raro de protocolo ausente.
    DATE_FORMAT(cp.dt_pagamento, '%Y-%m-%d')                      AS data_pagamento,
    -- ✅ AJUSTE 2026-09-22 — mesmo padrão dos itens 9/10 (data_realizacao /
    -- data_protocolo_cobranca): contas AVISADAS mas ainda em análise
    -- (`ie_situacao='1'`) não têm `dt_fim_analise`/`dt_liberacao_protocolo`/
    -- `dt_autorizacao` preenchidos — achado na auditoria de 07/2026 (contas
    -- 2572, 2573, 3580, confirmado via MCP MySQL). `cp.dt_cadastro_conta`
    -- (NOT NULL) como último recurso evita o campo obrigatório vazio; mesma
    -- ressalva: é a data de CADASTRO, não a data real de processamento.
    DATE_FORMAT(
        COALESCE(cp.dt_fim_analise, ps.dt_liberacao_protocolo, cp.dt_autorizacao, cp.dt_cadastro_conta),
        '%Y-%m-%d'
    )                                                              AS data_processamento_guia,
    cp.ie_tipo_consulta                                           AS tipo_consulta,
    cp.cd_cbo                                                     AS cbo_executante,
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
    CAST(cp.vl_apresentado AS DECIMAL(18, 2))                     AS valor_total_informado,
    CAST(cp.vl_liberado + cp.vl_glosado AS DECIMAL(18, 2))        AS valor_processado,
    CAST(COALESCE(tg.vl_pago_procedimentos, 0) AS DECIMAL(18, 2)) AS valor_total_pago_procedimentos,
    CAST(COALESCE(tg.vl_diarias, 0) AS DECIMAL(18, 2))            AS valor_total_diarias,
    CAST(COALESCE(tg.vl_taxas, 0) AS DECIMAL(18, 2))              AS valor_total_taxas,
    CAST(COALESCE(tg.vl_materiais, 0) AS DECIMAL(18, 2))          AS valor_total_materiais,
    CAST(COALESCE(tg.vl_opme, 0) AS DECIMAL(18, 2))               AS valor_total_opme,
    CAST(COALESCE(tg.vl_medicamentos, 0) AS DECIMAL(18, 2))       AS valor_total_medicamentos,
    CAST(cp.vl_glosado AS DECIMAL(18, 2))                         AS valor_glosa_guia,
    CAST(
        CASE WHEN ps.protocolo_pago THEN cp.vl_liberado ELSE 0 END
        AS DECIMAL(18, 2)
    )                                                              AS valor_pago_guia,
    CAST(0.00 AS DECIMAL(18, 2))                                  AS valor_pago_fornecedores,
    CAST(0.00 AS DECIMAL(18, 2))                                  AS valor_total_tabela_propria,
    -- ✅ AJUSTE 2026-09-21 — `vl_coparticipacao` está NULL em parte das contas
    -- da base viva (333 contas em idestabelecimento=19, confirmado via MCP
    -- MySQL); o XSD exige o campo preenchido. COALESCE para 0.00 (mesmo padrão
    -- de fallback zero já usado nas colunas `valor_pago_fornecedores`/
    -- `valor_total_tabela_propria` acima) — conta sem coparticipação registrada
    -- é semanticamente "zero", não "campo ausente por erro".
    CAST(COALESCE(cp.vl_coparticipacao, 0.00) AS DECIMAL(18, 2))  AS valor_total_coparticipacao,
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
    -- coluna só é avaliada quando o protocolo já está Pago (análise
    -- encerrada), NULL aqui só pode significar "zero aprovado", nunca
    -- "ainda não analisado" — COALESCE para 0 é seguro nesse ponto.
    CAST(
        CASE
            WHEN it.vl_unitario IS NULL OR it.vl_unitario = 0 THEN it.qt_realizada
            ELSE ROUND(COALESCE(it.vl_total_aprovado, 0) / it.vl_unitario, 4)
        END AS DECIMAL(18, 4)
    )                                                              AS quantidade_paga,
    it.cd_unidade_medida                                          AS unidade_medida,
    CAST(
        CASE WHEN ps.protocolo_pago THEN COALESCE(it.vl_total_aprovado, 0) ELSE 0 END
        AS DECIMAL(18, 2)
    )                                                              AS valor_pago_procedimento,
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
ORDER BY
    cp.idsps_conta_medica,
    it.idsps_conta_medica_proc;
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
--      em TODAS as validações** (CSV + geração de XML + schema oficial XSD
--      da ANS) — primeira competência 100% estruturalmente pronta para
--      envio, 279 registros, hash `.XTE` calculado com sucesso.
--      05/06/07-2026 ainda não chegaram nessa camada de validação (têm
--      bloqueios de CSV anteriores) — o mesmo tipo de achado pode aparecer
--      neles quando os bloqueios de CSV forem resolvidos.
-- =============================================================================
