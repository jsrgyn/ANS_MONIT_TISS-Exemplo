import { BLOCK_TYPES } from "./constants.js";

const common = ["tipo_bloco", "chave_registro", "tipo_registro"];

const guideBase = [
  ...common,
  "forma_envio",
  "executante_cnes",
  "executante_tipo_identificacao",
  "executante_cpf_cnpj",
  "executante_municipio",
  "beneficiario_sexo",
  "beneficiario_data_nascimento",
  "beneficiario_municipio_residencia",
  "plano_registro",
  "tipo_evento_atencao",
  "origem_evento_atencao",
  "numero_guia_prestador",
  "numero_guia_operadora",
  "identificacao_reembolso",
  "data_realizacao",
  "data_protocolo_cobranca",
  "data_processamento_guia",
  "valor_total_informado",
  "valor_processado",
  "valor_total_pago_procedimentos",
  "valor_total_diarias",
  "valor_total_taxas",
  "valor_total_materiais",
  "valor_total_opme",
  "valor_total_medicamentos",
  "valor_glosa_guia",
  "valor_pago_guia",
  "valor_pago_fornecedores",
  "valor_total_tabela_propria",
  "valor_total_coparticipacao",
];

const guideItem = [
  "procedimento_codigo_tabela",
  "procedimento_grupo",
  "procedimento_codigo",
  "dente_codigo",
  "regiao_codigo",
  "dente_face",
  "quantidade_informada",
  "valor_informado",
  "quantidade_paga",
  "unidade_medida",
  "valor_pago_procedimento",
  "valor_pago_fornecedor",
  "fornecedor_cnpj",
  "valor_coparticipacao_procedimento",
  "detalhes_pacote",
];

const directSupplyBase = [
  ...common,
  "beneficiario_sexo",
  "beneficiario_data_nascimento",
  "beneficiario_municipio_residencia",
  "plano_registro",
  "identificacao_fornecimento_direto",
  "data_fornecimento",
  "valor_total_fornecimento",
  "valor_total_tabela_propria",
  "valor_total_coparticipacao",
];

const directSupplyItem = [
  "procedimento_codigo_tabela",
  "procedimento_grupo",
  "procedimento_codigo",
  "quantidade_fornecida",
  "unidade_medida",
  "valor_fornecido",
  "valor_coparticipacao_procedimento",
];

export const CSV_LAYOUTS = Object.freeze({
  [BLOCK_TYPES.GUIA]: {
    required: [
      ...guideBase,
      ...guideItem.filter(
        (field) =>
          ![
            "procedimento_grupo",
            "procedimento_codigo",
            "dente_codigo",
            "regiao_codigo",
            "dente_face",
            "unidade_medida",
            "fornecedor_cnpj",
            "detalhes_pacote",
          ].includes(field),
      ),
    ],
    itemFields: guideItem,
  },
  [BLOCK_TYPES.FORNECIMENTO_DIRETO]: {
    required: [
      ...directSupplyBase,
      ...directSupplyItem.filter(
        (field) => !["procedimento_grupo", "procedimento_codigo", "unidade_medida"].includes(field),
      ),
    ],
    itemFields: directSupplyItem,
  },
  [BLOCK_TYPES.OUTRA_REMUNERACAO]: {
    required: [
      ...common,
      "data_processamento",
      "recebedor_tipo_identificacao",
      "recebedor_cpf_cnpj",
      "valor_total_informado",
      "valor_total_glosa",
      "valor_total_pago",
    ],
    itemFields: [],
  },
  [BLOCK_TYPES.VALOR_PREESTABELECIDO]: {
    required: [
      ...common,
      "competencia_cobertura",
      "identificacao_valor_preestabelecido",
      "valor_preestabelecido",
    ],
    itemFields: [],
  },
});

export const DATE_FIELDS = new Set([
  "beneficiario_data_nascimento",
  "data_solicitacao",
  "data_autorizacao",
  "data_realizacao",
  "data_inicial_faturamento",
  "data_fim_periodo",
  "data_protocolo_cobranca",
  "data_pagamento",
  "data_processamento_guia",
  "data_fornecimento",
  "data_processamento",
]);

export const DECIMAL_FIELDS = new Set([
  "valor_remuneracao",
  "valor_total_informado",
  "valor_processado",
  "valor_total_pago_procedimentos",
  "valor_total_diarias",
  "valor_total_taxas",
  "valor_total_materiais",
  "valor_total_opme",
  "valor_total_medicamentos",
  "valor_glosa_guia",
  "valor_pago_guia",
  "valor_pago_fornecedores",
  "valor_total_tabela_propria",
  "valor_total_coparticipacao",
  "quantidade_informada",
  "valor_informado",
  "quantidade_paga",
  "valor_pago_procedimento",
  "valor_pago_fornecedor",
  "valor_coparticipacao_procedimento",
  "valor_total_fornecimento",
  "valor_fornecido",
  "valor_total_glosa",
  "valor_total_pago",
  "valor_preestabelecido",
]);

export const DOCUMENT_FIELDS = new Set([
  "executante_cpf_cnpj",
  "beneficiario_cpf",
  "fornecedor_cnpj",
  "recebedor_cpf_cnpj",
  "prestador_cpf_cnpj",
]);
