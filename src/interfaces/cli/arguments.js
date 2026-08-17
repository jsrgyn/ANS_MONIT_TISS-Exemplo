import { parseArgs } from "node:util";
import { AppError } from "../../shared/errors.js";

export function parseGenerateArguments() {
  const { values } = parseArgs({
    options: {
      csv: { type: "string" },
      "registro-ans": { type: "string" },
      competencia: { type: "string" },
      "numero-lote": { type: "string" },
      sequencial: { type: "string", default: "0001" },
      output: { type: "string", default: "output" },
      "sem-movimento": { type: "boolean", default: false },
      ajuda: { type: "boolean", short: "h", default: false },
      help: { type: "boolean", default: false },
    },
    allowPositionals: false,
  });

  if (values.ajuda || values.help) return { help: true };
  const missing = ["registro-ans", "competencia", "numero-lote"].filter((name) => !values[name]);
  if (!values["sem-movimento"] && !values.csv) missing.push("csv");
  if (missing.length > 0)
    throw new AppError(`Argumentos obrigatórios ausentes: ${missing.join(", ")}.`);

  return {
    csvPath: values.csv,
    outputDirectory: values.output,
    noMovement: values["sem-movimento"],
    metadata: {
      registroAns: values["registro-ans"],
      competencia: values.competencia,
      numeroLote: values["numero-lote"],
      sequencialArquivo: values.sequencial,
    },
  };
}

export function generateHelp() {
  return `Uso:
  npm run gerar -- --csv examples/csv/guia_monitoramento.csv \\
    --registro-ans 123456 --competencia 202607 --numero-lote LOTE0001 \\
    --sequencial 0001 --output output

Sem movimento:
  npm run gerar -- --sem-movimento --registro-ans 123456 \\
    --competencia 202607 --numero-lote LOTE0002 --sequencial 0002
`;
}
