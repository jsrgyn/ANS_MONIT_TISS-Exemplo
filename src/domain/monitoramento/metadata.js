import { TISS_MONITORING_VERSION, TRANSACTION_TYPE } from "./constants.js";
import { AppError } from "../../shared/errors.js";

export function normalizeMetadata(input, now = new Date()) {
  const metadata = {
    transactionType: TRANSACTION_TYPE,
    batchNumber: String(input.numeroLote ?? input.batchNumber ?? "").trim(),
    competence: normalizeCompetence(input.competencia ?? input.competence ?? ""),
    registrationDate: String(
      input.dataRegistro ?? input.registrationDate ?? formatDate(now),
    ).trim(),
    registrationTime: normalizeTime(
      input.horaRegistro ?? input.registrationTime ?? formatTime(now),
    ),
    ansRegistration: String(
      input.registroAns ?? input.registroANS ?? input.ansRegistration ?? "",
    ).trim(),
    standardVersion: TISS_MONITORING_VERSION,
    fileSequence: String(input.sequencialArquivo ?? input.fileSequence ?? "0001")
      .trim()
      .padStart(4, "0"),
  };

  const details = [];
  if (!/^\d{6}$/.test(metadata.ansRegistration)) {
    details.push({ campo: "registro_ans", mensagem: "Informe exatamente 6 dígitos." });
  }
  if (!/^\d{6}$/.test(metadata.competence) || !isValidCompetence(metadata.competence)) {
    details.push({ campo: "competencia", mensagem: "Use AAAAMM ou MM/AAAA com um mês válido." });
  }
  if (!metadata.batchNumber || metadata.batchNumber.length > 12) {
    details.push({ campo: "numero_lote", mensagem: "Informe de 1 a 12 caracteres." });
  }
  if (!/^\d{4}$/.test(metadata.fileSequence)) {
    details.push({
      campo: "sequencial_arquivo",
      mensagem: "Informe um sequencial entre 0000 e 9999.",
    });
  }
  if (
    !/^\d{4}-\d{2}-\d{2}$/.test(metadata.registrationDate) ||
    !isValidCalendarDate(metadata.registrationDate)
  ) {
    details.push({ campo: "data_registro", mensagem: "Use AAAA-MM-DD." });
  }
  if (
    !/^\d{2}:\d{2}:\d{2}$/.test(metadata.registrationTime) ||
    !isValidTime(metadata.registrationTime)
  ) {
    details.push({ campo: "hora_registro", mensagem: "Use HH:MM:SS ou HHMMSS." });
  }
  if (
    details.length === 0 &&
    isFutureTransaction(metadata.registrationDate, metadata.registrationTime, now)
  ) {
    details.push({
      campo: "data_registro",
      mensagem: "A data/hora de registro não pode estar no futuro.",
    });
  }

  if (details.length > 0) {
    throw new AppError("Parâmetros do cabeçalho inválidos.", {
      statusCode: 422,
      code: "CABECALHO_INVALIDO",
      details,
    });
  }

  return metadata;
}

export function buildXteFileName(metadata) {
  return `${metadata.ansRegistration}${metadata.competence}${metadata.fileSequence}.XTE`;
}

function formatDate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function formatTime(date) {
  return [date.getHours(), date.getMinutes(), date.getSeconds()]
    .map((part) => String(part).padStart(2, "0"))
    .join(":");
}

function isValidCompetence(value) {
  const month = Number(value.slice(4));
  return month >= 1 && month <= 12;
}

function normalizeCompetence(value) {
  const text = String(value ?? "").trim();
  const brazilian = /^(\d{2})\/(\d{4})$/.exec(text);
  return brazilian ? `${brazilian[2]}${brazilian[1]}` : text.replace(/[-/]/g, "");
}

function normalizeTime(value) {
  const text = String(value ?? "").trim();
  if (/^\d{6}$/.test(text)) return `${text.slice(0, 2)}:${text.slice(2, 4)}:${text.slice(4)}`;
  return text;
}

function isValidCalendarDate(value) {
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day
  );
}

function isValidTime(value) {
  const [hours, minutes, seconds] = value.split(":").map(Number);
  return (
    hours >= 0 && hours <= 23 && minutes >= 0 && minutes <= 59 && seconds >= 0 && seconds <= 59
  );
}

function isFutureTransaction(date, time, now) {
  const [year, month, day] = date.split("-").map(Number);
  const [hours, minutes, seconds] = time.split(":").map(Number);
  return new Date(year, month - 1, day, hours, minutes, seconds).getTime() > now.getTime();
}
