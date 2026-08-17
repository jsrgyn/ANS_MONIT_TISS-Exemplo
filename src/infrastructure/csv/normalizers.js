import { AppError } from "../../shared/errors.js";

export function decodeCsv(buffer) {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(buffer).replace(/^\uFEFF/, "");
  } catch {
    return new TextDecoder("iso-8859-1").decode(buffer);
  }
}

export function normalizeHeader(value) {
  return String(value)
    .trim()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");
}

export function normalizeDate(value) {
  const text = String(value ?? "").trim();
  if (!text) return "";

  const brazilian = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(text);
  if (brazilian) return `${brazilian[3]}-${brazilian[2]}-${brazilian[1]}`;
  return text;
}

export function normalizeCompetence(value) {
  const text = String(value ?? "").trim();
  const brazilian = /^(\d{2})\/(\d{4})$/.exec(text);
  return brazilian ? `${brazilian[2]}${brazilian[1]}` : text.replace(/[-/]/g, "");
}

export function normalizeDecimal(value) {
  const text = String(value ?? "")
    .trim()
    .replace(/\s/g, "");
  if (!text) return "";
  if (text.includes(",") && text.includes(".")) return text.replace(/\./g, "").replace(",", ".");
  return text.replace(",", ".");
}

export function normalizeDocument(value) {
  return String(value ?? "")
    .trim()
    .toUpperCase()
    .replace(/[.\-/\s]/g, "");
}

export function assertLatin1(value, field = "valor") {
  for (const character of String(value)) {
    if (character.codePointAt(0) > 255) {
      throw new AppError(
        `O campo '${field}' contém caractere fora de ISO-8859-1: '${character}'.`,
        {
          statusCode: 422,
          code: "CARACTERE_FORA_LATIN1",
        },
      );
    }
  }
}
