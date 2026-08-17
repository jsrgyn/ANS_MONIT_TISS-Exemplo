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
    throw new XmlValidationError(
      "O XML gerado não passou na validação do schema oficial da ANS.",
      validation.errors,
    );
  }

  return {
    ...generated,
    fileName: buildXteFileName(metadata),
    blockType: noMovement ? "sem_movimento" : parsed.blockType,
    recordCount: parsed.records.length,
    rowsRead: parsed.rowsRead,
    metadata,
    validation,
  };
}
