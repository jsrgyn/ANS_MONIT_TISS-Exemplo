import fs from "node:fs/promises";
import { parseArgs } from "node:util";
import { validateMonitoringFile } from "../../application/validate-monitoring-file.js";

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    ajuda: { type: "boolean", short: "h", default: false },
    help: { type: "boolean", default: false },
  },
});
if (values.ajuda || values.help) {
  console.info("Uso: npm run validar -- caminho/arquivo.XTE");
} else if (positionals.length !== 1) {
  console.error("Uso: npm run validar -- caminho/arquivo.XTE");
  process.exitCode = 1;
} else {
  try {
    const buffer = await fs.readFile(positionals[0]);
    const result = await validateMonitoringFile(buffer);

    if (result.isValid) {
      console.info(
        `XML válido no XSD ${result.xsd.schemaVersion}; encoding ${result.encoding.expected} e hash MD5 conferem.`,
      );
    } else {
      if (!result.encoding.isValid) {
        for (const error of result.encoding.errors) console.error(error.formatted);
      }
      if (!result.xsd.isValid) {
        for (const error of result.xsd.errors) console.error(error.formatted);
      }
      if (!result.hash.isValid) {
        console.error(
          `[HASH] Informado: ${result.hash.informed || "ausente"}; calculado: ${result.hash.calculated || "indisponível"}.`,
        );
      }
      process.exitCode = 1;
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
