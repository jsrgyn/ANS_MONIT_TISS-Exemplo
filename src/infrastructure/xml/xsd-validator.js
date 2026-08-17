import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { validateXML as xmllintValidate } from "xmllint-wasm";
import { TISS_MONITORING_VERSION } from "../../domain/monitoramento/constants.js";

const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
const schemaDirectory = path.resolve(
  currentDirectory,
  "../../../schemas/tiss",
  TISS_MONITORING_VERSION,
);
const mainSchemaName = "tissMonitoramentoV1_06_00.xsd";
const simpleSchemaName = "tissSimpleTypesMonitoramentoV1_06_00.xsd";
const complexSchemaName = "tissComplexTypesMonitoramentoV1_06_00.xsd";

let schemaPromise;

export async function validateXmlAgainstAnsSchema(xml) {
  const schemas = await loadSchemas();
  try {
    const result = await xmllintValidate({
      xml: [{ fileName: "arquivo.XTE", contents: xml }],
      schema: [schemas.main],
      preload: [
        { fileName: simpleSchemaName, contents: schemas.simple },
        { fileName: complexSchemaName, contents: schemas.complex },
      ],
      initialMemoryPages: 512,
      maxMemoryPages: 4096,
    });

    return {
      isValid: result.valid,
      errors: result.errors.map(formatError),
      rawOutput: result.rawOutput,
      engine: "libxml2 (xmllint-wasm)",
      schemaVersion: TISS_MONITORING_VERSION,
    };
  } catch (error) {
    return {
      isValid: false,
      errors: [{ line: 0, column: 0, message: error.message, formatted: `[XSD] ${error.message}` }],
      rawOutput: error.message,
      engine: "libxml2 (xmllint-wasm)",
      schemaVersion: TISS_MONITORING_VERSION,
    };
  }
}

async function loadSchemas() {
  if (!schemaPromise) {
    schemaPromise = Promise.all([
      fs.readFile(path.join(schemaDirectory, mainSchemaName), "latin1"),
      fs.readFile(path.join(schemaDirectory, simpleSchemaName), "latin1"),
      fs.readFile(path.join(schemaDirectory, complexSchemaName), "latin1"),
    ]).then(([main, simple, complex]) => ({
      main,
      simple,
      // O ZIP oficial 202511 referencia 1_05_01, arquivo que não existe no pacote.
      // O schema principal já inclui o simple type 1_06_00; retirar somente esse include
      // obsoleto permite que o mesmo libxml2 usado pelo XML Tools compile o conjunto oficial.
      complex: complex.replace(
        /\s*<include schemaLocation="tissSimpleTypesMonitoramentoV1_05_01\.xsd"\/>/,
        "",
      ),
    }));
  }
  return schemaPromise;
}

function formatError(error) {
  const line = error.loc?.lineNumber ?? 0;
  const column = error.loc?.columnNumber ?? error.loc?.column ?? 0;
  const message = String(error.message ?? error.rawMessage ?? "Erro de validação")
    .replace(/^.*?Schemas validity error\s*:\s*/i, "")
    .trim();
  return {
    line,
    column,
    message,
    element: extractElementName(message),
    severity: "error",
    formatted: `[XSD] Linha ${line || "?"}, coluna ${column || "?"}: ${message}`,
  };
}

function extractElementName(message) {
  const qualified = /Element ['"]\{[^}]+\}([^'"]+)['"]/.exec(message)?.[1];
  return qualified ?? /Element ['"]([^'"]+)['"]/.exec(message)?.[1] ?? "";
}
