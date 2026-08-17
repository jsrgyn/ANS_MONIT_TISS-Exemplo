import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: {
    "include-large": { type: "boolean", default: false },
    force: { type: "boolean", default: false },
  },
});

const manifest = JSON.parse(await fsp.readFile("docs/ans/manifest.json", "utf8"));
const core = manifest.artifacts.map((artifact) => ({
  ...artifact,
  destination: path.join("docs/ans/originais", artifact.file),
}));
const large = manifest.largeArtifacts.map((artifact) => ({
  ...artifact,
  destination: path.join("var/ans-cache", artifact.file),
}));

for (const artifact of values["include-large"] ? [...core, ...large] : core) {
  await download(artifact, values.force);
}

async function download(artifact, force) {
  await fsp.mkdir(path.dirname(artifact.destination), { recursive: true });

  if (!force && (await exists(artifact.destination))) {
    const checksum = await sha256(artifact.destination);
    if (!artifact.sha256 || checksum === artifact.sha256) {
      console.info(
        `[OK] ${artifact.destination} já existe${artifact.sha256 ? " e o SHA-256 confere" : ""}.`,
      );
      return;
    }
    throw new Error(
      `Checksum divergente em ${artifact.destination}. Use --force para baixar novamente.`,
    );
  }

  const response = await fetch(artifact.url, {
    headers: { "user-agent": "ANS-TISS-Monitoramento/1.0" },
  });
  if (!response.ok || !response.body)
    throw new Error(`Falha HTTP ${response.status} ao baixar ${artifact.url}.`);

  const temporary = `${artifact.destination}.download`;
  await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(temporary, { flags: "w" }));
  const checksum = await sha256(temporary);
  if (artifact.sha256 && checksum !== artifact.sha256) {
    await fsp.unlink(temporary);
    throw new Error(`SHA-256 inválido para ${artifact.file}: ${checksum}.`);
  }
  await fsp.rename(temporary, artifact.destination);
  console.info(`[OK] ${artifact.destination} baixado. SHA-256: ${checksum}`);
}

async function sha256(filePath) {
  const hash = crypto.createHash("sha256");
  await pipeline(fs.createReadStream(filePath), hash);
  return hash.digest("hex");
}

async function exists(filePath) {
  try {
    await fsp.access(filePath);
    return true;
  } catch {
    return false;
  }
}
