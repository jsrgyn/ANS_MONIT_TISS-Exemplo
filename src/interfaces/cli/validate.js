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
    const declaration = buffer.subarray(0, 160).toString("ascii");
    const xml = /encoding=["']ISO-8859-1["']/i.test(declaration)
      ? buffer.toString("latin1")
      : buffer.toString("utf8");
    const result = await validateMonitoringFile(xml);

    if (result.isValid) {
      console.info(`XML válido no XSD ${result.xsd.schemaVersion}; hash MD5 confere.`);
    } else {
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
