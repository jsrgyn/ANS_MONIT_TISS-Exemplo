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
  DECIMAL_FIELD_RULES,
  DIGIT_FIELDS,
  DOCUMENT_FIELDS,
  ENUM_FIELDS,
  INTEGER_FIELDS,
  TEXT_MAX_LENGTHS,
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
  findNonLatin1Character,
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
      {
        linha: error.lines ?? 0,
        coluna: Number(error.column) || 0,
        campo: typeof error.column === "string" ? error.column : "-",
        mensagem: error.message,
      },
    ]);
  }

  if (rows.length === 0) {
    throw new CsvValidationError("O CSV não possui linhas de dados.", []);
  }

  const duplicateHeaders = headers.filter((header, index) => headers.indexOf(header) !== index);
  if (duplicateHeaders.length > 0) {
    throwCsvValidation(
      "O CSV possui cabeçalhos duplicados.",
      [
        {
          linha: 1,
          campo: duplicateHeaders[0],
          mensagem: "Cabeçalho duplicado após normalização.",
        },
      ],
      headers,
    );
  }

  const blockTypes = new Set(rows.map((row) => row.tipo_bloco));
  if (blockTypes.size !== 1 || !VALID_BLOCK_TYPES.has([...blockTypes][0])) {
    throwCsvValidation(
      "Cada CSV deve conter exatamente um tipo de bloco suportado.",
      [
        {
          linha: 1,
          campo: "tipo_bloco",
          mensagem: `Use apenas um destes valores: ${[...VALID_BLOCK_TYPES].join(", ")}.`,
        },
      ],
      headers,
    );
  }

  const blockType = [...blockTypes][0];
  const layout = CSV_LAYOUTS[blockType];
  const missingHeaderErrors = layout.required
    .filter((field) => !headers.includes(field))
    .map((field) => ({ linha: 1, campo: field, mensagem: "Coluna obrigatória ausente." }));
  const unknownHeaderErrors = headers
    .filter((field) => !layout.columns.includes(field))
    .map((field) => ({
      linha: 1,
      campo: field,
      mensagem: `Coluna não reconhecida no layout '${blockType}'. Corrija o cabeçalho ou remova-a.`,
    }));
  const headerErrors = [...missingHeaderErrors, ...unknownHeaderErrors];

  if (headerErrors.length > 0) {
    throwCsvValidation(
      "O cabeçalho do CSV não atende ao layout selecionado.",
      headerErrors,
      headers,
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
    validateSchemaFields(blockType, normalized, line, errors);
    validateBlockFields(blockType, normalized, line, errors);
    return { ...normalized, _linha: line };
  });

  if (errors.length > 0) {
    throwCsvValidation("Foram encontrados erros nos dados do CSV.", errors, headers);
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
    throwCsvValidation("Não foi possível agrupar os registros do CSV.", errors, headers);
  }

  return {
    blockType,
    records,
    rowsRead: rows.length,
    fieldColumns: Object.fromEntries(headers.map((field, index) => [field, index + 1])),
  };
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
    if (
      !DECIMAL_PATTERN.test(row[field]) ||
      !fitsDecimalRule(row[field], DECIMAL_FIELD_RULES[field])
    ) {
      const rule = DECIMAL_FIELD_RULES[field];
      errors.push({
        linha: line,
        campo: field,
        mensagem: `Decimal inválido; use até ${rule.totalDigits} dígitos no total e ${rule.fractionDigits} casas, sem milhar ou sinal.`,
      });
    }
  }

  for (const [field, value] of Object.entries(row)) {
    if (field.includes("competencia") && value && !isValidCompetence(value)) {
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

  for (const [field, value] of Object.entries(row)) {
    const invalidCharacter = value && findNonLatin1Character(value);
    if (invalidCharacter) {
      errors.push({
        linha: line,
        campo: field,
        mensagem: `Caractere '${invalidCharacter}' não pode ser representado em ISO-8859-1.`,
      });
    }
  }
}

function validateSchemaFields(blockType, row, line, errors) {
  for (const [field, allowed] of Object.entries(ENUM_FIELDS)) {
    if (!row[field] || !Object.hasOwn(row, field) || allowed.includes(row[field])) continue;
    errors.push({
      linha: line,
      campo: field,
      mensagem: `Valor fora do domínio do XSD 01.06.00. Valores aceitos: ${allowed.join(", ")}.`,
    });
  }

  for (const [field, maxLength] of Object.entries(TEXT_MAX_LENGTHS)) {
    if (!row[field] || row[field].length <= maxLength) continue;
    errors.push({
      linha: line,
      campo: field,
      mensagem: `O XSD permite no máximo ${maxLength} caractere(s).`,
    });
  }

  for (const [field, limits] of Object.entries(DIGIT_FIELDS)) {
    if (!row[field]) continue;
    const expression = new RegExp(`^\\d{${limits.min},${limits.max}}$`);
    if (!expression.test(row[field])) {
      errors.push({
        linha: line,
        campo: field,
        mensagem:
          limits.min === limits.max
            ? `Informe exatamente ${limits.min} dígitos.`
            : `Informe somente dígitos, entre ${limits.min} e ${limits.max} posições.`,
      });
    }
  }

  for (const [field, maxDigits] of Object.entries(INTEGER_FIELDS)) {
    if (!row[field] || new RegExp(`^\\d{1,${maxDigits}}$`).test(row[field])) continue;
    errors.push({
      linha: line,
      campo: field,
      mensagem: `Informe um inteiro não negativo com até ${maxDigits} dígitos.`,
    });
  }

  if (row.procedimento_grupo && !/^\d{3}$/.test(row.procedimento_grupo)) {
    errors.push({
      linha: line,
      campo: "procedimento_grupo",
      mensagem: "O grupo de procedimento deve conter exatamente 3 dígitos.",
    });
  }
  if (
    blockType === BLOCK_TYPES.FORNECIMENTO_DIRETO &&
    row.procedimento_codigo &&
    !/^[A-Z0-9]{1,10}$/i.test(row.procedimento_codigo)
  ) {
    errors.push({
      linha: line,
      campo: "procedimento_codigo",
      mensagem: "Use de 1 a 10 caracteres alfanuméricos.",
    });
  }

  validateStructuredLists(row, line, errors);

  if (row.operadora_intermediaria_tipo_atendimento && !row.operadora_intermediaria_registro) {
    errors.push({
      linha: line,
      campo: "operadora_intermediaria_tipo_atendimento",
      mensagem: "O tipo de atendimento exige o registro da operadora intermediária.",
    });
  }

  if (
    row.data_inicial_faturamento &&
    row.data_fim_periodo &&
    row.data_inicial_faturamento > row.data_fim_periodo
  ) {
    errors.push({
      linha: line,
      campo: "data_fim_periodo",
      mensagem: "A data final não pode ser anterior à data inicial de faturamento.",
    });
  }

  if (
    blockType === BLOCK_TYPES.FORNECIMENTO_DIRETO &&
    row.beneficiario_data_nascimento &&
    row.beneficiario_data_nascimento < "1850-01-01"
  ) {
    errors.push({
      linha: line,
      campo: "beneficiario_data_nascimento",
      mensagem: "O XSD exige data igual ou posterior a 1850-01-01 neste bloco.",
    });
  }
}

function validateStructuredLists(row, line, errors) {
  validateSimpleList(row.diagnosticos_cid10, {
    field: "diagnosticos_cid10",
    line,
    errors,
    maxItems: 4,
    itemPattern: /^[A-Z0-9]{1,4}$/i,
    description: "CID com 1 a 4 caracteres alfanuméricos",
  });
  for (const field of ["declaracoes_nascido", "declaracoes_obito"]) {
    validateSimpleList(row[field], {
      field,
      line,
      errors,
      maxItems: 8,
      itemPattern: /^[A-Z0-9]{1,11}$/i,
      description: "identificador com 1 a 11 caracteres alfanuméricos",
    });
  }

  for (const item of splitList(row.formas_remuneracao)) {
    const parts = item.split(":");
    const value = normalizeDecimal(parts[1]);
    if (
      parts.length !== 2 ||
      !["01", "02", "03", "04", "05", "06", "07"].includes(parts[0]) ||
      !DECIMAL_PATTERN.test(value) ||
      !fitsDecimalRule(value, { totalDigits: 10, fractionDigits: 2 })
    ) {
      errors.push({
        linha: line,
        campo: "formas_remuneracao",
        mensagem: `Item '${item}' inválido. Use CODIGO:VALOR, com código de 01 a 07 e decimal 10,2.`,
      });
    }
  }

  for (const item of splitList(row.detalhes_pacote)) {
    const parts = item.split(":");
    const quantity = normalizeDecimal(parts[2]);
    const unit = parts[3] ?? "";
    if (
      ![3, 4].includes(parts.length) ||
      !["18", "19", "20", "22"].includes(parts[0]) ||
      !/^[A-Z0-9]{1,10}$/i.test(parts[1] ?? "") ||
      !DECIMAL_PATTERN.test(quantity) ||
      !fitsDecimalRule(quantity, { totalDigits: 12, fractionDigits: 4 }) ||
      (unit && !ENUM_FIELDS.unidade_medida.includes(unit))
    ) {
      errors.push({
        linha: line,
        campo: "detalhes_pacote",
        mensagem: `Item '${item}' inválido. Use TABELA:CODIGO:QUANTIDADE[:UNIDADE] conforme o XSD.`,
      });
    }
  }
}

function validateSimpleList(value, options) {
  const items = splitList(value);
  if (items.length > options.maxItems) {
    options.errors.push({
      linha: options.line,
      campo: options.field,
      mensagem: `O XSD aceita no máximo ${options.maxItems} item(ns) separados por '|'.`,
    });
  }
  if (items.some((item) => !options.itemPattern.test(item))) {
    options.errors.push({
      linha: options.line,
      campo: options.field,
      mensagem: `Lista inválida; cada item deve ser ${options.description}.`,
    });
  }
}

function splitList(value) {
  return String(value ?? "")
    .split("|")
    .map((item) => item.trim())
    .filter(Boolean);
}

function fitsDecimalRule(value, rule) {
  if (!rule || !DECIMAL_PATTERN.test(value)) return false;
  const [integer, fraction = ""] = value.split(".");
  const significantInteger = integer.replace(/^0+/, "");
  const totalDigits = (significantInteger || "0").length + fraction.length;
  return fraction.length <= rule.fractionDigits && totalDigits <= rule.totalDigits;
}

function isValidCompetence(value) {
  return /^\d{6}$/.test(value) && Number(value.slice(4)) >= 1 && Number(value.slice(4)) <= 12;
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
  if (!["1", "2"].includes(type)) return;
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
      Object.fromEntries([
        ...itemFields.map((field) => [field, row[field] ?? ""]),
        ["sourceLine", row._linha],
      ]),
    );
    records.push({ ...base, items, sourceLines: groupedRows.map((row) => row._linha) });
  }
  return records;
}

function throwCsvValidation(message, errors, headers) {
  const details = errors.map((error) => {
    const headerIndex = headers.indexOf(error.campo);
    const column = error.coluna || (headerIndex >= 0 ? headerIndex + 1 : 0);
    return {
      ...error,
      coluna: column,
      localizacao: `L${error.linha || "?"}:C${column || "?"}`,
    };
  });
  throw new CsvValidationError(message, details);
}
