import express from "express";
import helmet from "helmet";
import pinoHttp from "pino-http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import multer from "multer";
import { apiRouter } from "./routes.js";
import { logger } from "../../shared/logger.js";
import { AppError } from "../../shared/errors.js";

const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
const publicDirectory = path.resolve(currentDirectory, "../../../public");

export function createApp() {
  const app = express();
  app.disable("x-powered-by");
  app.use(helmet({ contentSecurityPolicy: false }));
  app.use(
    pinoHttp({ logger, autoLogging: { ignore: (request) => request.url === "/api/v1/health" } }),
  );
  app.use(express.json({ limit: "1mb" }));
  app.use(express.static(publicDirectory, { extensions: ["html"] }));
  app.use("/api/v1", apiRouter);

  app.use((_request, response) => {
    response.status(404).json({ code: "ROTA_NAO_ENCONTRADA", message: "Rota não encontrada." });
  });

  app.use((error, _request, response, _next) => {
    if (error instanceof multer.MulterError && error.code === "LIMIT_FILE_SIZE") {
      response
        .status(413)
        .json({ code: "ARQUIVO_MUITO_GRANDE", message: "O arquivo excede o limite configurado." });
      return;
    }

    const known = error instanceof AppError;
    if (!known) logger.error({ err: error }, "Falha não tratada na requisição");
    response.status(known ? error.statusCode : 500).json({
      code: known ? error.code : "ERRO_INTERNO",
      message: known ? error.message : "Erro interno do servidor.",
      details: known ? error.details : undefined,
    });
  });

  return app;
}
