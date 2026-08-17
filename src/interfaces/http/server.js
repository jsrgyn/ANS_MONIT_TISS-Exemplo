import { createApp } from "./app.js";
import { env } from "../../config/env.js";
import { logger } from "../../shared/logger.js";

const server = createApp().listen(env.PORT, env.HOST, () => {
  logger.info(
    { host: env.HOST, port: env.PORT },
    `Monitoramento TISS disponível em http://${env.HOST}:${env.PORT}`,
  );
});

let closing = false;

function shutdown(signal) {
  if (closing) return;
  closing = true;
  logger.info({ signal }, "Encerrando servidor");
  server.close((error) => {
    if (error) {
      logger.error({ err: error }, "Falha ao encerrar servidor");
      process.exitCode = 1;
    }
  });
}

process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
