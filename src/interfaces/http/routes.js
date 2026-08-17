import { Router } from "express";
import { generateMonitoringFile } from "../../application/generate-monitoring-file.js";
import { validateMonitoringFile } from "../../application/validate-monitoring-file.js";
import { AppError } from "../../shared/errors.js";
import { uploadCsv, uploadXml } from "./upload.js";

export const apiRouter = Router();

apiRouter.get("/health", (_request, response) => {
  response.json({ status: "ok", schemaVersion: "1.06.00" });
});

apiRouter.post("/monitoramento/gerar", uploadCsv.single("arquivo"), async (request, response) => {
  const noMovement = ["true", "1", "on"].includes(String(request.body.sem_movimento).toLowerCase());
  const result = await generateMonitoringFile({
    csvBuffer: request.file?.buffer,
    noMovement,
    metadata: {
      registroAns: request.body.registro_ans,
      competencia: request.body.competencia,
      numeroLote: request.body.numero_lote,
      sequencialArquivo: request.body.sequencial_arquivo,
    },
  });

  response.status(201).json({
    fileName: result.fileName,
    blockType: result.blockType,
    recordCount: result.recordCount,
    rowsRead: result.rowsRead,
    hash: result.hash,
    validation: result.validation,
    contentBase64: result.buffer.toString("base64"),
  });
});

apiRouter.post("/monitoramento/validar", uploadXml.single("arquivo"), async (request, response) => {
  if (!request.file) throw new AppError("Envie o arquivo XTE/XML no campo 'arquivo'.");
  const declaration = request.file.buffer.subarray(0, 160).toString("ascii");
  const xml = /encoding=["']ISO-8859-1["']/i.test(declaration)
    ? request.file.buffer.toString("latin1")
    : request.file.buffer.toString("utf8");
  const result = await validateMonitoringFile(xml);
  response.status(result.isValid ? 200 : 422).json(result);
});
