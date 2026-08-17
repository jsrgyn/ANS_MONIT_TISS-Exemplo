import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { generateMonitoringFile } from "../src/application/generate-monitoring-file.js";
import { validateMonitoringFile } from "../src/application/validate-monitoring-file.js";

const examples = [
  "guia_monitoramento",
  "fornecimento_direto",
  "outra_remuneracao",
  "valor_preestabelecido",
];
const now = new Date("2026-08-09T10:30:00-03:00");
const metadata = {
  registroAns: "123456",
  competencia: "202607",
  numeroLote: "LOTE0001",
  sequencialArquivo: "0001",
};

for (const example of examples) {
  test(`gera ${example} e valida no XSD 01.06.00`, async () => {
    const result = await generateMonitoringFile({
      csvBuffer: fs.readFileSync(`examples/csv/${example}.csv`),
      metadata,
      now,
    });
    assert.equal(result.validation.isValid, true);
    assert.match(result.xml, /<versaoPadrao>1\.06\.00<\/versaoPadrao>/);
    assert.equal(
      result.buffer.subarray(0, 43).toString("latin1"),
      '<?xml version="1.0" encoding="ISO-8859-1"?>',
    );
  });
}

test("gera o arquivo sem movimento com o código oficial 5016", async () => {
  const result = await generateMonitoringFile({ metadata, noMovement: true, now });
  assert.match(result.xml, /<semMovimentoInclusao>5016<\/semMovimentoInclusao>/);
  assert.equal(result.recordCount, 0);
});

test("detecta alteração no conteúdo pelo hash mesmo quando o XSD continua válido", async () => {
  const generated = await generateMonitoringFile({
    csvBuffer: fs.readFileSync("examples/csv/outra_remuneracao.csv"),
    metadata,
    now,
  });
  const tampered = generated.xml.replace("1500.00", "1501.00");
  const validation = await validateMonitoringFile(tampered);
  assert.equal(validation.xsd.isValid, true);
  assert.equal(validation.hash.isValid, false);
  assert.equal(validation.isValid, false);
});

test("retorna erro no estilo XML Tools para elemento fora da ordem", async () => {
  const generated = await generateMonitoringFile({ metadata, noMovement: true, now });
  const invalid = generated.xml.replace("<registroANS>123456</registroANS>", "");
  const validation = await validateMonitoringFile(invalid);
  assert.equal(validation.xsd.isValid, false);
  assert.match(validation.xsd.errors[0].formatted, /^\[XSD\] Linha/);
});
