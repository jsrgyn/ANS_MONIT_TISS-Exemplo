import pino from "pino";
import { env } from "../config/env.js";

export const logger = pino({
  level: env.LOG_LEVEL,
  redact: {
    paths: ["req.headers.authorization", "req.body", "records", "xml"],
    censor: "[REDACTED]",
  },
  base: undefined,
});
