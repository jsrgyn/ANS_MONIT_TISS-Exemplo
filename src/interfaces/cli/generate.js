import fs from "node:fs/promises";
import path from "node:path";
import { generateMonitoringFile } from "../../application/generate-monitoring-file.js";
import { generateHelp, parseGenerateArguments } from "./arguments.js";

try {
  const options = parseGenerateArguments();
  if (options.help) {
    console.info(generateHelp());
    process.exitCode = 0;
  } else {
    const csvBuffer = options.noMovement ? undefined : await fs.readFile(options.csvPath);
    const result = await generateMonitoringFile({
      csvBuffer,
      metadata: options.metadata,
      noMovement: options.noMovement,
    });
    await fs.mkdir(options.outputDirectory, { recursive: true });
    const outputPath = path.resolve(options.outputDirectory, result.fileName);
    await fs.writeFile(outputPath, result.buffer);
    console.info(`Arquivo gerado e validado: ${outputPath}`);
    console.info(
      `Bloco: ${result.blockType} | Registros: ${result.recordCount} | Hash: ${result.hash}`,
    );
  }
} catch (error) {
  console.error(error.message);
  for (const detail of error.details ?? []) {
    console.error(
      `- linha ${detail.linha ?? "-"}, ${detail.campo ?? "-"}: ${detail.mensagem ?? detail.message}`,
    );
  }
  process.exitCode = 1;
}
