import multer from "multer";
import { env } from "../../config/env.js";
import { AppError } from "../../shared/errors.js";

export const uploadCsv = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: env.MAX_FILE_SIZE_BYTES, files: 1 },
  fileFilter: (_request, file, callback) => {
    if (!file.originalname.toLowerCase().endsWith(".csv")) {
      callback(
        new AppError("Envie um arquivo com extensão .csv.", { code: "TIPO_ARQUIVO_INVALIDO" }),
      );
      return;
    }
    callback(null, true);
  },
});

export const uploadXml = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: env.MAX_FILE_SIZE_BYTES, files: 1 },
  fileFilter: (_request, file, callback) => {
    if (!/\.(xml|xte)$/i.test(file.originalname)) {
      callback(new AppError("Envie um arquivo .XTE ou .xml.", { code: "TIPO_ARQUIVO_INVALIDO" }));
      return;
    }
    callback(null, true);
  },
});
