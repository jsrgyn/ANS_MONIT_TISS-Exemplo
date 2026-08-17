import crypto from "node:crypto";
import { create } from "xmlbuilder2";
import {
  BLOCK_TYPES,
  BLOCK_XML_ELEMENTS,
  NO_MOVEMENT_CODE,
  TISS_NAMESPACE,
} from "../../domain/monitoramento/constants.js";
import { assertLatin1, normalizeDecimal } from "../csv/normalizers.js";
import { AppError } from "../../shared/errors.js";

export function buildMonitoringXml({ metadata, blockType, records = [], noMovement = false }) {
  const document = create({ version: "1.0", encoding: "ISO-8859-1" });
  const root = document.ele(TISS_NAMESPACE, "mensagemEnvioANS");
  const hashParts = [];
  const writer = createWriter(hashParts);

  const header = root.ele("cabecalho");
  const transaction = header.ele("identificacaoTransacao");
  writer.text(transaction, "tipoTransacao", metadata.transactionType);
  writer.text(transaction, "numeroLote", metadata.batchNumber);
  writer.text(transaction, "competenciaLote", metadata.competence);
  writer.text(transaction, "dataRegistroTransacao", metadata.registrationDate);
  writer.text(transaction, "horaRegistroTransacao", metadata.registrationTime);
  writer.text(header, "registroANS", metadata.ansRegistration);
  writer.text(header, "versaoPadrao", metadata.standardVersion);

  const message = root.ele("Mensagem");
  const operatorToAns = message.ele("operadoraParaANS");

  if (noMovement) {
    writer.text(operatorToAns, "semMovimentoInclusao", NO_MOVEMENT_CODE);
  } else {
    const elementName = BLOCK_XML_ELEMENTS[blockType];
    if (!elementName) throw new AppError(`Tipo de bloco não suportado: ${blockType}.`);
    for (const record of records) {
      const element = operatorToAns.ele(elementName);
      appendRecord(writer, element, blockType, record);
    }
  }

  const hash = crypto
    .createHash("md5")
    .update(Buffer.from(hashParts.join(""), "latin1"))
    .digest("hex")
    .toUpperCase();
  const epilogue = root.ele("epilogo");
  epilogue.ele("hash").txt(hash);

  const xml = document.end({ prettyPrint: true, indent: "  ", newline: "\r\n" });
  assertLatin1(xml, "xml");
  return { xml, hash, buffer: Buffer.from(xml, "latin1") };
}

function appendRecord(writer, parent, blockType, record) {
  switch (blockType) {
    case BLOCK_TYPES.GUIA:
      return appendGuide(writer, parent, record);
    case BLOCK_TYPES.FORNECIMENTO_DIRETO:
      return appendDirectSupply(writer, parent, record);
    case BLOCK_TYPES.OUTRA_REMUNERACAO:
      return appendOtherRemuneration(writer, parent, record);
    case BLOCK_TYPES.VALOR_PREESTABELECIDO:
      return appendPreestablishedValue(writer, parent, record);
    default:
      throw new AppError(`Tipo de bloco não suportado: ${blockType}.`);
  }
}

function appendGuide(writer, parent, row) {
  writer.text(parent, "tipoRegistro", row.tipo_registro);
  writer.optional(parent, "versaoTISSPrestador", row.versao_tiss_prestador);
  writer.text(parent, "formaEnvio", row.forma_envio);

  const provider = parent.ele("dadosContratadoExecutante");
  writer.text(provider, "CNES", row.executante_cnes);
  writer.text(provider, "identificadorExecutante", row.executante_tipo_identificacao);
  writer.text(provider, "codigoCNPJ_CPF", row.executante_cpf_cnpj);
  writer.text(provider, "municipioExecutante", row.executante_municipio);
  writer.optional(
    parent,
    "registroANSOperadoraIntermediaria",
    row.operadora_intermediaria_registro,
  );
  writer.optional(
    parent,
    "tipoAtendimentoOperadoraIntermediaria",
    row.operadora_intermediaria_tipo_atendimento,
  );

  appendBeneficiary(writer, parent, row, false);
  writer.text(parent, "tipoEventoAtencao", row.tipo_evento_atencao);
  writer.text(parent, "origemEventoAtencao", row.origem_evento_atencao);
  writer.text(parent, "numeroGuia_prestador", row.numero_guia_prestador);
  writer.text(parent, "numeroGuia_operadora", row.numero_guia_operadora);
  writer.text(parent, "identificacaoReembolso", row.identificacao_reembolso);
  writer.optional(
    parent,
    "identificacaoValorPreestabelecido",
    row.identificacao_valor_preestabelecido,
  );

  for (const remuneration of parseRemunerations(row.formas_remuneracao)) {
    const element = parent.ele("formasRemuneracao");
    writer.text(element, "formaRemuneracao", remuneration.code);
    writer.text(element, "valorRemuneracao", remuneration.value);
  }

  writer.optional(parent, "guiaSolicitacaoInternacao", row.guia_solicitacao_internacao);
  writer.optional(parent, "dataSolicitacao", row.data_solicitacao);
  writer.optional(parent, "numeroGuiaSPSADTPrincipal", row.numero_guia_spsadt_principal);
  writer.optional(parent, "dataAutorizacao", row.data_autorizacao);
  writer.text(parent, "dataRealizacao", row.data_realizacao);
  writer.optional(parent, "dataInicialFaturamento", row.data_inicial_faturamento);
  writer.optional(parent, "dataFimPeriodo", row.data_fim_periodo);
  writer.text(parent, "dataProtocoloCobranca", row.data_protocolo_cobranca);
  writer.optional(parent, "dataPagamento", row.data_pagamento);
  writer.text(parent, "dataProcessamentoGuia", row.data_processamento_guia);
  writer.optional(parent, "tipoConsulta", row.tipo_consulta);
  writer.optional(parent, "cboExecutante", row.cbo_executante);
  writer.optional(parent, "indicacaoRecemNato", row.indicacao_recem_nato);
  writer.optional(parent, "indicacaoAcidente", row.indicacao_acidente);
  writer.optional(parent, "caraterAtendimento", row.carater_atendimento);
  writer.optional(parent, "tipoInternacao", row.tipo_internacao);
  writer.optional(parent, "regimeInternacao", row.regime_internacao);

  const diagnoses = parsePipeValues(row.diagnosticos_cid10);
  if (diagnoses.length > 0) {
    const element = parent.ele("diagnosticosCID10");
    for (const diagnosis of diagnoses) writer.text(element, "diagnosticoCID", diagnosis);
  }

  writer.optional(parent, "tipoAtendimento", row.tipo_atendimento);
  writer.optional(parent, "regimeAtendimento", row.regime_atendimento);
  writer.optional(parent, "saudeOcupacional", row.saude_ocupacional);
  writer.optional(parent, "tipoFaturamento", row.tipo_faturamento);
  writer.optional(parent, "diariasAcompanhante", row.diarias_acompanhante);
  writer.optional(parent, "diariasUTI", row.diarias_uti);
  writer.optional(parent, "motivoSaida", row.motivo_saida);

  const values = parent.ele("valoresGuia");
  writer.text(values, "valorTotalInformado", row.valor_total_informado);
  writer.text(values, "valorProcessado", row.valor_processado);
  writer.text(values, "valorTotalPagoProcedimentos", row.valor_total_pago_procedimentos);
  writer.text(values, "valorTotalDiarias", row.valor_total_diarias);
  writer.text(values, "valorTotalTaxas", row.valor_total_taxas);
  writer.text(values, "valorTotalMateriais", row.valor_total_materiais);
  writer.text(values, "valorTotalOPME", row.valor_total_opme);
  writer.text(values, "valorTotalMedicamentos", row.valor_total_medicamentos);
  writer.text(values, "valorGlosaGuia", row.valor_glosa_guia);
  writer.text(values, "valorPagoGuia", row.valor_pago_guia);
  writer.text(values, "valorPagoFornecedores", row.valor_pago_fornecedores);
  writer.text(values, "valorTotalTabelaPropria", row.valor_total_tabela_propria);
  writer.text(values, "valorTotalCoParticipacao", row.valor_total_coparticipacao);

  for (const value of parsePipeValues(row.declaracoes_nascido))
    writer.text(parent, "declaracaoNascido", value);
  for (const value of parsePipeValues(row.declaracoes_obito))
    writer.text(parent, "declaracaoObito", value);
  for (const item of row.items) appendGuideProcedure(writer, parent.ele("procedimentos"), item);
}

function appendGuideProcedure(writer, parent, item) {
  appendProcedureIdentification(writer, parent, item, true);
  appendToothRegion(writer, parent, item);
  writer.optional(parent, "denteFace", item.dente_face);
  writer.text(parent, "quantidadeInformada", item.quantidade_informada);
  writer.text(parent, "valorInformado", item.valor_informado);
  writer.text(parent, "quantidadePaga", item.quantidade_paga);
  writer.optional(parent, "unidadeMedida", item.unidade_medida);
  writer.text(parent, "valorPagoProc", item.valor_pago_procedimento);
  writer.text(parent, "valorPagoFornecedor", item.valor_pago_fornecedor);
  writer.optional(parent, "CNPJFornecedor", item.fornecedor_cnpj);
  writer.text(parent, "valorCoParticipacao", item.valor_coparticipacao_procedimento);

  for (const detail of parsePackageDetails(item.detalhes_pacote)) {
    const element = parent.ele("detalhePacote");
    writer.text(element, "codigoTabela", detail.table);
    writer.text(element, "codigoProcedimento", detail.code);
    writer.text(element, "quantidade", detail.quantity);
    writer.optional(element, "unidadeMedida", detail.unit);
  }
}

function appendDirectSupply(writer, parent, row) {
  writer.text(parent, "tipoRegistro", row.tipo_registro);
  appendBeneficiary(writer, parent, row, true);
  writer.text(parent, "identificacaoFornecimentoDireto", row.identificacao_fornecimento_direto);
  writer.text(parent, "dataFornecimento", row.data_fornecimento);
  writer.text(parent, "valorTotalFornecimento", row.valor_total_fornecimento);
  writer.text(parent, "valorTotalTabelaPropria", row.valor_total_tabela_propria);
  writer.text(parent, "valorTotalCoParticipacao", row.valor_total_coparticipacao);

  for (const item of row.items) {
    const procedure = parent.ele("procedimentos");
    appendProcedureIdentification(writer, procedure, item, false);
    writer.text(procedure, "quantidadeFornecida", item.quantidade_fornecida);
    writer.optional(procedure, "unidadeMedida", item.unidade_medida);
    writer.text(procedure, "valorFornecido", item.valor_fornecido);
    writer.text(procedure, "valorCoParticipacao", item.valor_coparticipacao_procedimento);
  }
}

function appendOtherRemuneration(writer, parent, row) {
  writer.text(parent, "tipoRegistro", row.tipo_registro);
  writer.text(parent, "dataProcessamento", row.data_processamento);
  const recipient = parent.ele("dadosRecebedor");
  writer.text(recipient, "identificadorRecebedor", row.recebedor_tipo_identificacao);
  writer.text(recipient, "codigoCNPJ_CPF", row.recebedor_cpf_cnpj);
  writer.text(parent, "valorTotalInformado", row.valor_total_informado);
  writer.text(parent, "valorTotalGlosa", row.valor_total_glosa);
  writer.text(parent, "valorTotalPago", row.valor_total_pago);
}

function appendPreestablishedValue(writer, parent, row) {
  writer.text(parent, "tipoRegistro", row.tipo_registro);
  writer.text(parent, "competenciaCoberturaContratada", row.competencia_cobertura);

  if (row.operadora_intermediaria_registro) {
    writer.text(parent, "registroANSOperadoraIntermediaria", row.operadora_intermediaria_registro);
  } else {
    const provider = parent.ele("dadosPrestador");
    writer.text(provider, "CNES", row.prestador_cnes);
    writer.text(provider, "identificadorPrestador", row.prestador_tipo_identificacao);
    writer.text(provider, "codigoCNPJ_CPF", row.prestador_cpf_cnpj);
    writer.text(provider, "municipioPrestador", row.prestador_municipio);
  }

  writer.text(parent, "identificacaoValorPreestabelecido", row.identificacao_valor_preestabelecido);
  writer.text(parent, "valorPreestabelecido", row.valor_preestabelecido);
}

function appendBeneficiary(writer, parent, row, directSupply) {
  const beneficiary = parent.ele("dadosBeneficiario");
  const identification = beneficiary.ele("identBeneficiario");
  const target = directSupply ? identification.ele("dadosSemCartao") : identification;
  writer.optional(target, "numeroCartaoNacionalSaude", row.beneficiario_cns);
  writer.optional(target, "cpfBeneficiario", row.beneficiario_cpf);
  writer.text(target, "sexo", row.beneficiario_sexo);
  writer.text(target, "dataNascimento", row.beneficiario_data_nascimento);
  writer.text(target, "municipioResidencia", row.beneficiario_municipio_residencia);
  writer.text(beneficiary, "numeroRegistroPlano", row.plano_registro);
}

function appendProcedureIdentification(writer, parent, item, guide) {
  const identification = parent.ele("identProcedimento");
  writer.text(identification, "codigoTabela", item.procedimento_codigo_tabela);
  const procedure = identification.ele(guide ? "Procedimento" : "procedimento");
  if (item.procedimento_grupo) writer.text(procedure, "grupoProcedimento", item.procedimento_grupo);
  else writer.text(procedure, "codigoProcedimento", item.procedimento_codigo);
}

function appendToothRegion(writer, parent, item) {
  if (!item.dente_codigo && !item.regiao_codigo) return;
  const element = parent.ele("denteRegiao");
  if (item.dente_codigo) writer.text(element, "codDente", item.dente_codigo);
  else writer.text(element, "codRegiao", item.regiao_codigo);
}

function parsePipeValues(value) {
  return String(value ?? "")
    .split("|")
    .map((item) => item.trim())
    .filter(Boolean);
}

function parseRemunerations(value) {
  return parsePipeValues(value).map((item) => {
    const [code, rawValue] = item.split(":");
    if (!code || rawValue === undefined)
      throw new AppError(`Forma de remuneração inválida: '${item}'. Use CODIGO:VALOR.`);
    return { code, value: normalizeDecimal(rawValue) };
  });
}

function parsePackageDetails(value) {
  return parsePipeValues(value).map((item) => {
    const [table, code, rawQuantity, unit = ""] = item.split(":");
    if (!table || !code || !rawQuantity) {
      throw new AppError(
        `Detalhe de pacote inválido: '${item}'. Use TABELA:CODIGO:QUANTIDADE[:UNIDADE].`,
      );
    }
    return { table, code, quantity: normalizeDecimal(rawQuantity), unit };
  });
}

function createWriter(hashParts) {
  return {
    text(parent, name, rawValue) {
      const value = String(rawValue ?? "");
      assertLatin1(value, name);
      parent.ele(name).txt(value);
      hashParts.push(value);
    },
    optional(parent, name, rawValue) {
      if (rawValue === undefined || rawValue === null || rawValue === "") return;
      this.text(parent, name, rawValue);
    },
  };
}
