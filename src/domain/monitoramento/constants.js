export const TISS_NAMESPACE = "http://www.ans.gov.br/padroes/tiss/schemas";
export const TISS_MONITORING_VERSION = "1.06.00";
export const TRANSACTION_TYPE = "MONITORAMENTO";
export const NO_MOVEMENT_CODE = "5016";

export const BLOCK_TYPES = Object.freeze({
  GUIA: "guia",
  FORNECIMENTO_DIRETO: "fornecimento_direto",
  OUTRA_REMUNERACAO: "outra_remuneracao",
  VALOR_PREESTABELECIDO: "valor_preestabelecido",
});

export const BLOCK_XML_ELEMENTS = Object.freeze({
  [BLOCK_TYPES.GUIA]: "guiaMonitoramento",
  [BLOCK_TYPES.FORNECIMENTO_DIRETO]: "fornecimentoDiretoMonitoramento",
  [BLOCK_TYPES.OUTRA_REMUNERACAO]: "outraRemuneracaoMonitoramento",
  [BLOCK_TYPES.VALOR_PREESTABELECIDO]: "valorPreestabelecidoMonitoramento",
});

export const MAX_RECORDS_PER_FILE = 10_000;
export const ZERO_GUIDE_NUMBER = "00000000000000000000";
