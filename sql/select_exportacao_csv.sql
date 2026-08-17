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
-- "SPS - Custo Médico do usuário por prestador.txt", bandas 5375/5377):
--   • AVISADO   = sps_conta_medica.vl_apresentado           (o que o prestador cobrou)
--   • LIBERADO  = sps_conta_medica.vl_liberado               ("programado para
--                 pagamento": valor aprovado na análise, ainda não
--                 necessariamente pago)
--   • PAGO      = sps_conta_medica.vl_liberado, reconhecido como pago SOMENTE
--                 quando o protocolo (sps_protocolo_conta_medica.ie_situacao)
--                 atingiu '3' (Pago) — replicando a regra usada no relatório-fonte
--                 (lá aplicada via log de evento; aqui simplificada para o
--                 estado atual do protocolo, pois este é um export de
--                 "foto atual", não uma reconstrução histórica por período).
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
--   :dt_inicio, :dt_fim  -- ✅ período de referência (competência) do arquivo,
--                            formato AAAA-MM-DD; fim é INCLUSIVO (a query soma
--                            1 dia internamente, mesmo padrão do relatório-fonte)
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
--   • Garantir índice em sps_conta_medica (idestabelecimento, ie_situacao,
--     dt_autorizacao) — filtro primário desta consulta;
--   • Garantir índice em sps_conta_medica_proc (idsps_conta_medica) — já é FK,
--     mas confirmar que existe índice (não apenas a constraint);
--   • Garantir índice em sps_protocolo_conta_medica (idsps_protocolo_conta_medica)
--     (PK, já garantido) e em sps_conta_medica (idsps_protocolo_conta_medica);
--   • As CTEs de endereço (`beneficiario_endereco`) usam ROW_NUMBER() para
--     eliminar potenciais duplicidades de complemento/logradouro — evita
--     explosão de linhas (fan-out) antes do JOIN com os procedimentos, que é
--     o produto cartesiano relevante (1 conta × N procedimentos);
--   • Rodar sempre com `:dt_inicio`/`:dt_fim` curtos (a competência do lote);
--     nunca sem filtro de período — sps_conta_medica_proc pode ser a maior
--     tabela do escopo.
-- =============================================================================

WITH
parametros AS (
    SELECT
        CAST(:idestabelecimento AS UNSIGNED)                AS idestabelecimento,
        CAST(:dt_inicio AS DATE)                             AS dt_inicio,
        DATE_ADD(CAST(:dt_fim AS DATE), INTERVAL 1 DAY)      AS dt_fim_exclusivo,
        NULLIF(CAST(:idprestador AS UNSIGNED), 0)            AS idprestador,
        COALESCE(NULLIF(CAST(:forma_envio AS CHAR), ''), '3')            AS forma_envio,
        COALESCE(NULLIF(CAST(:versao_tiss_prestador AS CHAR), ''), '027') AS versao_tiss_prestador,
        COALESCE(NULLIF(CAST(:tipo_registro AS CHAR), ''), '1')          AS tipo_registro
),

-- -----------------------------------------------------------------------------
-- Contas médicas do período/prestador/estabelecimento, já processadas
-- (ie_situacao IN ('3','4') = Liberada para pagamento / Pago — Domínio 870,
-- ✅ confirmado em modelagem.md §4.5). Contas ainda em '0'/'1'/'2' (recebida /
-- em análise / análise finalizada sem liberação) não fazem sentido em um
-- arquivo de Monitoramento, que reporta o resultado do processamento.
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
        cm.nr_guia_operadora,                   -- 🔴 nome presumido por simetria
                                                 --    com nr_guia_prestador; confirmar via
                                                 --    SHOW CREATE TABLE sps_conta_medica
        cm.dt_autorizacao,                      -- ✅
        cm.dt_inicio_faturamento,               -- ✅
        cm.dt_fim_faturamento,                  -- ✅
        cm.dt_inicio_analise,                   -- ✅
        cm.dt_fim_analise,                      -- ✅
        cm.dt_pagamento,                        -- ✅
        cm.dt_alta,                             -- ✅
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
    INNER JOIN sps_protocolo_conta_medica pcm
            ON pcm.idsps_protocolo_conta_medica = cm.idsps_protocolo_conta_medica
           AND pcm.status = 'A'
    CROSS JOIN parametros p
    WHERE cm.status = 'A'
      AND cm.idestabelecimento = p.idestabelecimento
      AND cm.ie_situacao IN ('3', '4')                    -- Liberada p/ pagamento | Pago (domínio 870)
      AND cm.dt_autorizacao >= p.dt_inicio
      AND cm.dt_autorizacao <  p.dt_fim_exclusivo
      AND (p.idprestador IS NULL OR cm.idsps_prestador_exec = p.idprestador)
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
        pcm.dt_pagamento_protocolo                 -- ✅
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
-- Dados do prestador executante: CNES/CNPJ (pessoa_juridica — ✅ cd_cnes e cnpj
-- confirmados em padroes_sql.md "Help de prestador"). Prestador Pessoa Física
-- (profissional autônomo, identificador TISS '2' = CPF) é tratado via
-- sps_prestador.idpessoa_fisica — 🟡 assumido por simetria com o restante do
-- sistema (contrato, beneficiário etc. também resolvem PF/PJ por par de FKs
-- opcionais); confirmar a existência da coluna antes deux produção.
-- Município do executante: 🔴 não localizado em nenhuma fonte desta sessão
-- (sem acesso ao MCP MySQL ao vivo). Mantém-se aqui a hipótese mais provável
-- (coluna direta em pessoa_juridica) com fallback em parâmetro fixo — AJUSTE
-- OBRIGATÓRIO antes de uso em produção, ver nota no final do arquivo.
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
        COALESCE(pj.cd_municipio_ibge, pf.cd_municipio_ibge)      AS municipio_bruto -- 🔴 ESBOÇO: revisar
    FROM sps_prestador sp
    LEFT JOIN pessoa_juridica pj ON pj.idpessoa_juridica = sp.idpessoa_juridica -- ✅
    LEFT JOIN pessoa_fisica  pf ON pf.idpessoa_fisica  = sp.idpessoa_fisica     -- 🟡 ESBOÇO: confirmar coluna
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

    pd.cnes                                                       AS executante_cnes,
    pd.tipo_identificacao_tiss                                    AS executante_tipo_identificacao,
    pd.cpf_cnpj                                                   AS executante_cpf_cnpj,
    LEFT(COALESCE(pd.municipio_bruto, ''), 6)                     AS executante_municipio,

    NULL                                                          AS operadora_intermediaria_registro,
    NULL                                                          AS operadora_intermediaria_tipo_atendimento,

    bd.nr_cartao_nac_sus                                          AS beneficiario_cns,
    bd.nr_cpf                                                     AS beneficiario_cpf,
    bd.sexo_tiss                                                  AS beneficiario_sexo,
    DATE_FORMAT(bd.dt_nascimento, '%Y-%m-%d')                     AS beneficiario_data_nascimento,
    bd.municipio_ibge                                             AS beneficiario_municipio_residencia,
    bd.plano_registro                                             AS plano_registro,

    cp.ie_tipo_guia_tiss                                          AS tipo_evento_atencao,
    cp.ie_origem_conta                                            AS origem_evento_atencao,
    cp.nr_guia_prestador                                          AS numero_guia_prestador,
    COALESCE(cp.nr_guia_operadora, cp.nr_guia_prestador)          AS numero_guia_operadora,
    REPEAT('0', 20)                                               AS identificacao_reembolso,
    NULL                                                          AS identificacao_valor_preestabelecido,
    NULL                                                          AS formas_remuneracao,

    NULL                                                          AS guia_solicitacao_internacao,
    NULL                                                          AS data_solicitacao,
    NULL                                                          AS numero_guia_spsadt_principal,
    DATE_FORMAT(cp.dt_autorizacao, '%Y-%m-%d')                    AS data_autorizacao,
    DATE_FORMAT(
        COALESCE(cp.dt_inicio_faturamento, cp.dt_autorizacao),
        '%Y-%m-%d'
    )                                                              AS data_realizacao,
    DATE_FORMAT(cp.dt_inicio_faturamento, '%Y-%m-%d')             AS data_inicial_faturamento,
    DATE_FORMAT(cp.dt_fim_faturamento, '%Y-%m-%d')                AS data_fim_periodo,
    DATE_FORMAT(
        COALESCE(ps.dt_recebimento, cp.dt_autorizacao),
        '%Y-%m-%d'
    )                                                              AS data_protocolo_cobranca,
    DATE_FORMAT(cp.dt_pagamento, '%Y-%m-%d')                      AS data_pagamento,
    DATE_FORMAT(
        COALESCE(cp.dt_fim_analise, ps.dt_liberacao_protocolo, cp.dt_autorizacao),
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
    cp.ie_tipo_atendimento_tiss                                   AS tipo_atendimento,
    cp.ie_regime_atendimento_tiss                                 AS regime_atendimento,
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
    CAST(cp.vl_coparticipacao AS DECIMAL(18, 2))                  AS valor_total_coparticipacao,

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
    CAST(
        CASE
            WHEN it.vl_unitario IS NULL OR it.vl_unitario = 0 THEN it.qt_realizada
            ELSE ROUND(it.vl_total_aprovado / it.vl_unitario, 4)
        END AS DECIMAL(18, 4)
    )                                                              AS quantidade_paga,
    it.cd_unidade_medida                                          AS unidade_medida,
    CAST(
        CASE WHEN ps.protocolo_pago THEN it.vl_total_aprovado ELSE 0 END
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
-- Ajustes obrigatórios antes de rodar em produção (itens 🔴/🟡 desta sessão,
-- sem acesso ao MCP MySQL ao vivo — ver docs/modelagem_sys/modelagem.md §9):
--
-- 1. `prestador_dados.municipio_bruto` — nenhuma fonte disponível confirmou o
--    nome da coluna de município em `pessoa_juridica`/`pessoa_fisica`. Rode
--    `SHOW CREATE TABLE pessoa_juridica` e `SHOW CREATE TABLE pessoa_fisica`
--    e ajuste `pj.cd_municipio_ibge`/`pf.cd_municipio_ibge` para os nomes reais
--    (pode ser um FK `idmunicipio` exigindo JOIN com `municipio`, como já feito
--    para o beneficiário em `beneficiario_endereco`).
-- 2. `contas_periodo.nr_guia_operadora` — confirmar existência via
--    `SHOW CREATE TABLE sps_conta_medica`; se não existir, o COALESCE já
--    garante fallback para `nr_guia_prestador`.
-- 3. `prestador_dados` (JOIN com `pessoa_fisica` para prestador PF/autônomo) —
--    confirmar se `sps_prestador.idpessoa_fisica` existe; do contrário, remova
--    o LEFT JOIN e trate prestadores autônomos separadamente.
-- 4. Os indicadores `ie_*_tiss` (tipo_consulta, indicacao_acidente,
--    carater_atendimento, tipo_internacao, regime_*, saude_ocupacional,
--    tipo_faturamento, motivo_saida, tipo_evento_atencao, origem_evento_atencao)
--    são copiados como estão. O nome de cada coluna espelha 1:1 a terminologia
--    das tabelas de domínio TISS correspondentes, o que sugere fortemente que
--    já armazenam o código padrão ANS — mas isso não foi validado contra
--    `dominio_valor` nesta sessão (ver pendências em modelagem.md §9). Antes
--    do primeiro envio real, confira uma amostra desses códigos contra o
--    Componente Organizacional do TISS 01.06.00 (docs/ans/).
-- 5. `plano_registro` (numeroRegistroPlano) usa `sps_produto.nr_protocolo_ans`,
--    o mesmo campo usado na geração do arquivo SIB para "numeroPlanoANS" —
--    alta confiança, mas confirme que é o registro do PRODUTO (RPS) e não do
--    plano individual do beneficiário, caso a operadora distinga os dois.
-- =============================================================================
