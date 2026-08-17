import { parseMonitoringCsv } from "../infrastructure/csv/parse-monitoring-csv.js";
import { buildMonitoringXml } from "../infrastructure/xml/xml-builder.js";
import { validateXmlAgainstAnsSchema } from "../infrastructure/xml/xsd-validator.js";
import { buildXteFileName, normalizeMetadata } from "../domain/monitoramento/metadata.js";
import { XmlValidationError, AppError } from "../shared/errors.js";

export async function generateMonitoringFile({
  csvBuffer,
  metadata: rawMetadata,
  noMovement = false,
  now,
}) {
  const metadata = normalizeMetadata(rawMetadata, now);
  if (!noMovement && (!csvBuffer || csvBuffer.length === 0)) {
    throw new AppError("Envie um CSV ou marque a geração sem movimento.", {
      code: "CSV_NAO_ENVIADO",
    });
  }

  const parsed = noMovement
    ? { blockType: null, records: [], rowsRead: 0 }
    : parseMonitoringCsv(csvBuffer);

  const generated = buildMonitoringXml({
    metadata,
    blockType: parsed.blockType,
    records: parsed.records,
    noMovement,
  });
  const validation = await validateXmlAgainstAnsSchema(generated.xml);

  if (!validation.isValid) {
    const details = mapGeneratedXmlErrorsToCsv(
      validation.errors,
      generated.sourceMap,
      parsed.fieldColumns ?? {},
    );
    throw new XmlValidationError(
      "O XML gerado não passou na validação do schema oficial da ANS.",
      details,
    );
  }

  const generatedFile = { ...generated };
  delete generatedFile.sourceMap;
  return {
    ...generatedFile,
    fileName: buildXteFileName(metadata),
    blockType: noMovement ? "sem_movimento" : parsed.blockType,
    recordCount: parsed.records.length,
    rowsRead: parsed.rowsRead,
    metadata,
    validation,
  };
}

function mapGeneratedXmlErrorsToCsv(errors, sourceMap, fieldColumns) {
  return errors.map((error) => {
    const source = findNearestSource(sourceMap, error.line);
    if (!source) {
      return {
        ...error,
        linha: 0,
        coluna: 0,
        campo: "xml",
        mensagem: error.message,
        localizacao: `XML:L${error.line || "?"}:C${error.column || "?"}`,
      };
    }

    const column = fieldColumns[source.campo] ?? 0;
    return {
      ...error,
      linha: source.linha,
      coluna: column,
      campo: source.campo,
      mensagem: `${error.message} (XML gerado: linha ${error.line || "?"}).`,
      localizacao: `CSV:L${source.linha}:C${column || "?"}`,
      xmlLine: error.line,
    };
  });
}

function findNearestSource(sourceMap, line) {
  if (!line) return undefined;
  if (sourceMap[line]) return sourceMap[line];
  for (let distance = 1; distance <= 12; distance += 1) {
    if (sourceMap[line - distance]) return sourceMap[line - distance];
    if (sourceMap[line + distance]) return sourceMap[line + distance];
  }
  return undefined;
}
