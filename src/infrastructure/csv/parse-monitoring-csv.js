import { parse } from "csv-parse/sync";
import {
  BLOCK_TYPES,
  MAX_RECORDS_PER_FILE,
  ZERO_GUIDE_NUMBER,
} from "../../domain/monitoramento/constants.js";
import {
  CSV_LAYOUTS,
  DATE_FIELDS,
  DECIMAL_FIELDS,
  DOCUMENT_FIELDS,
} from "../../domain/monitoramento/csv-layouts.js";
import { isValidCnpj, isValidCpf } from "../../domain/monitoramento/tax-identifiers.js";
import { CsvValidationError } from "../../shared/errors.js";
import {
  decodeCsv,
  normalizeCompetence,
  normalizeDate,
  normalizeDecimal,
  normalizeDocument,
  normalizeHeader,
} from "./normalizers.js";

const VALID_BLOCK_TYPES = new Set(Object.values(BLOCK_TYPES));
const DECIMAL_PATTERN = /^\d+(?:\.\d+)?$/;
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

export function parseMonitoringCsv(buffer) {
  const text = decodeCsv(buffer);
  let headers = [];
  let rows;

  try {
    rows = parse(text, {
      bom: true,
      columns: (inputHeaders) => {
        headers = inputHeaders.map(normalizeHeader);
        return headers;
      },
      delimiter: ";",
      skip_empty_lines: true,
      trim: true,
      relax_column_count: false,
    });
  } catch (error) {
    throw new CsvValidationError("Não foi possível interpretar o CSV.", [
      { linha: error.lines ?? 0, campo: "-", mensagem: error.message },
    ]);
  }

  if (rows.length === 0) {
    throw new CsvValidationError("O CSV não possui linhas de dados.", []);
  }

  const duplicateHeaders = headers.filter((header, index) => headers.indexOf(header) !== index);
  if (duplicateHeaders.length > 0) {
    throw new CsvValidationError("O CSV possui cabeçalhos duplicados.", [
      { linha: 1, campo: duplicateHeaders[0], mensagem: "Cabeçalho duplicado após normalização." },
    ]);
  }

  const blockTypes = new Set(rows.map((row) => row.tipo_bloco));
  if (blockTypes.size !== 1 || !VALID_BLOCK_TYPES.has([...blockTypes][0])) {
    throw new CsvValidationError("Cada CSV deve conter exatamente um tipo de bloco suportado.", [
      {
        linha: 1,
        campo: "tipo_bloco",
        mensagem: `Use apenas um destes valores: ${[...VALID_BLOCK_TYPES].join(", ")}.`,
      },
    ]);
  }

  const blockType = [...blockTypes][0];
  const layout = CSV_LAYOUTS[blockType];
  const headerErrors = layout.required
    .filter((field) => !headers.includes(field))
    .map((field) => ({ linha: 1, campo: field, mensagem: "Coluna obrigatória ausente." }));

  if (headerErrors.length > 0) {
    throw new CsvValidationError(
      "O cabeçalho do CSV não atende ao layout selecionado.",
      headerErrors,
    );
  }

  const errors = [];
  const normalizedRows = rows.map((row, index) => {
    const line = index + 2;
    const normalized = normalizeRow(row);

    for (const field of layout.required) {
      if (normalized[field] === undefined || normalized[field] === "") {
        errors.push({ linha: line, campo: field, mensagem: "Campo obrigatório não preenchido." });
      }
    }

    validateCommonFields(normalized, line, errors);
    validateBlockFields(blockType, normalized, line, errors);
    return { ...normalized, _linha: line };
  });

  if (errors.length > 0) {
    throw new CsvValidationError("Foram encontrados erros nos dados do CSV.", errors);
  }

  const records = groupRows(normalizedRows, layout.itemFields, errors);
  if (records.length > MAX_RECORDS_PER_FILE) {
    errors.push({
      linha: 1,
      campo: "chave_registro",
      mensagem: `O XSD permite no máximo ${MAX_RECORDS_PER_FILE} registros por arquivo.`,
    });
  }

  if (errors.length > 0) {
    throw new CsvValidationError("Não foi possível agrupar os registros do CSV.", errors);
  }

  return { blockType, records, rowsRead: rows.length };
}

function normalizeRow(row) {
  const normalized = {};
  for (const [field, rawValue] of Object.entries(row)) {
    let value = String(rawValue ?? "").trim();
    if (DATE_FIELDS.has(field)) value = normalizeDate(value);
    if (DECIMAL_FIELDS.has(field)) value = normalizeDecimal(value);
    if (DOCUMENT_FIELDS.has(field)) value = normalizeDocument(value);
    if (field.includes("competencia")) value = normalizeCompetence(value);
    normalized[field] = value;
  }
  return normalized;
}

function validateCommonFields(row, line, errors) {
  if (row.tipo_registro && !["1", "2", "3"].includes(row.tipo_registro)) {
    errors.push({
      linha: line,
      campo: "tipo_registro",
      mensagem: "Use 1 (inclusão), 2 (alteração) ou 3 (exclusão).",
    });
  }

  for (const field of DATE_FIELDS) {
    if (!row[field]) continue;
    if (!DATE_PATTERN.test(row[field]) || !isValidCalendarDate(row[field])) {
      errors.push({
        linha: line,
        campo: field,
        mensagem: "Data inválida; use AAAA-MM-DD ou DD/MM/AAAA.",
      });
    }
  }

  for (const field of DECIMAL_FIELDS) {
    if (!row[field]) continue;
    if (!DECIMAL_PATTERN.test(row[field])) {
      errors.push({
        linha: line,
        campo: field,
        mensagem: "Valor numérico inválido; não use separador de milhar.",
      });
    }
  }

  for (const [field, value] of Object.entries(row)) {
    if (field.includes("competencia") && value && !/^\d{6}$/.test(value)) {
      errors.push({
        linha: line,
        campo: field,
        mensagem: "Competência inválida; use AAAAMM ou MM/AAAA.",
      });
    }
  }

  if (row.beneficiario_cpf && !isValidCpf(row.beneficiario_cpf)) {
    errors.push({
      linha: line,
      campo: "beneficiario_cpf",
      mensagem: "CPF com dígitos verificadores inválidos.",
    });
  }
  if (row.fornecedor_cnpj && !isValidCnpj(row.fornecedor_cnpj)) {
    errors.push({
      linha: line,
      campo: "fornecedor_cnpj",
      mensagem: "CNPJ com dígitos verificadores inválidos.",
    });
  }
}

function isValidCalendarDate(value) {
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day
  );
}

function validateBlockFields(blockType, row, line, errors) {
  if ([BLOCK_TYPES.GUIA, BLOCK_TYPES.FORNECIMENTO_DIRETO].includes(blockType)) {
    validateProcedureChoice(row, line, errors);
  }

  if (blockType === BLOCK_TYPES.GUIA) {
    validateExclusiveChoice(row, line, errors, "dente_codigo", "regiao_codigo", false);
    validateIdentifier(
      row.executante_tipo_identificacao,
      row.executante_cpf_cnpj,
      line,
      "executante_cpf_cnpj",
      errors,
    );

    if (
      ["1", "2", "3"].includes(row.origem_evento_atencao) &&
      row.identificacao_reembolso !== ZERO_GUIDE_NUMBER
    ) {
      errors.push({
        linha: line,
        campo: "identificacao_reembolso",
        mensagem: "Para origem 1, 2 ou 3, informe exatamente 20 zeros.",
      });
    }
    if (
      ["4", "5"].includes(row.origem_evento_atencao) &&
      row.identificacao_reembolso === ZERO_GUIDE_NUMBER
    ) {
      errors.push({
        linha: line,
        campo: "identificacao_reembolso",
        mensagem: "Para reembolso/prestador eventual, informe o identificador real, não 20 zeros.",
      });
    }
  }

  if (blockType === BLOCK_TYPES.OUTRA_REMUNERACAO) {
    validateIdentifier(
      row.recebedor_tipo_identificacao,
      row.recebedor_cpf_cnpj,
      line,
      "recebedor_cpf_cnpj",
      errors,
    );
  }

  if (blockType === BLOCK_TYPES.VALOR_PREESTABELECIDO) {
    const providerFields = [
      "prestador_cnes",
      "prestador_tipo_identificacao",
      "prestador_cpf_cnpj",
      "prestador_municipio",
    ];
    const providerValues = providerFields.filter((field) => row[field]);
    const hasIntermediary = Boolean(row.operadora_intermediaria_registro);

    if (
      (providerValues.length === 0 && !hasIntermediary) ||
      (providerValues.length > 0 && hasIntermediary)
    ) {
      errors.push({
        linha: line,
        campo: "prestador_cnes",
        mensagem: "Preencha o bloco completo do prestador ou somente a operadora intermediária.",
      });
    } else if (providerValues.length > 0 && providerValues.length !== providerFields.length) {
      errors.push({
        linha: line,
        campo: "prestador_cnes",
        mensagem: `O bloco do prestador exige: ${providerFields.join(", ")}.`,
      });
    } else if (providerValues.length === providerFields.length) {
      validateIdentifier(
        row.prestador_tipo_identificacao,
        row.prestador_cpf_cnpj,
        line,
        "prestador_cpf_cnpj",
        errors,
      );
    }
  }
}

function validateProcedureChoice(row, line, errors) {
  validateExclusiveChoice(row, line, errors, "procedimento_grupo", "procedimento_codigo", true);
}

function validateExclusiveChoice(row, line, errors, first, second, required) {
  const count = Number(Boolean(row[first])) + Number(Boolean(row[second]));
  if ((required && count !== 1) || (!required && count > 1)) {
    errors.push({
      linha: line,
      campo: first,
      mensagem: required
        ? `Preencha exatamente um entre '${first}' e '${second}'.`
        : `Preencha no máximo um entre '${first}' e '${second}'.`,
    });
  }
}

function validateIdentifier(type, value, line, field, errors) {
  if (!type || !value) return;
  const expected = type === "1" ? /^[A-Z0-9]{12}\d{2}$/ : /^\d{11}$/;
  if (!expected.test(value)) {
    errors.push({
      linha: line,
      campo: field,
      mensagem:
        type === "1"
          ? "CNPJ deve ter 12 caracteres alfanuméricos e 2 dígitos finais."
          : "CPF deve conter 11 dígitos.",
    });
    return;
  }
  if ((type === "1" && !isValidCnpj(value)) || (type === "2" && !isValidCpf(value))) {
    errors.push({
      linha: line,
      campo: field,
      mensagem:
        type === "1"
          ? "CNPJ com dígitos verificadores inválidos."
          : "CPF com dígitos verificadores inválidos.",
    });
  }
}

function groupRows(rows, itemFields, errors) {
  const groups = new Map();
  for (const row of rows) {
    const key = row.chave_registro;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }

  const records = [];
  for (const [key, groupedRows] of groups) {
    if (itemFields.length === 0 && groupedRows.length > 1) {
      errors.push({
        linha: groupedRows[1]._linha,
        campo: "chave_registro",
        mensagem: `A chave '${key}' está duplicada para um bloco sem itens repetíveis.`,
      });
      continue;
    }

    const first = groupedRows[0];
    const itemSet = new Set(itemFields);
    const ignored = new Set(["_linha", ...itemSet]);
    for (const row of groupedRows.slice(1)) {
      for (const [field, value] of Object.entries(first)) {
        if (ignored.has(field)) continue;
        if ((row[field] ?? "") !== value) {
          errors.push({
            linha: row._linha,
            campo: field,
            mensagem: `A chave '${key}' repete o registro com valor divergente do informado na linha ${first._linha}.`,
          });
        }
      }
    }

    const base = Object.fromEntries(Object.entries(first).filter(([field]) => !ignored.has(field)));
    const items = groupedRows.map((row) =>
      Object.fromEntries(itemFields.map((field) => [field, row[field] ?? ""])),
    );
    records.push({ ...base, items, sourceLines: groupedRows.map((row) => row._linha) });
  }
  return records;
}
