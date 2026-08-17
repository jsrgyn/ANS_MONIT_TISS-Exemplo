import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import request from "supertest";
import { createApp } from "../src/interfaces/http/app.js";
import { generateMonitoringFile } from "../src/application/generate-monitoring-file.js";

const app = createApp();

test("health check publica a versão do schema", async () => {
  const response = await request(app).get("/api/v1/health").expect(200);
  assert.deepEqual(response.body, { status: "ok", schemaVersion: "1.06.00" });
});

test("API recebe CSV, gera XTE e devolve o binário ISO-8859-1", async () => {
  const response = await request(app)
    .post("/api/v1/monitoramento/gerar")
    .field("registro_ans", "123456")
    .field("competencia", "202607")
    .field("numero_lote", "LOTE0001")
    .field("sequencial_arquivo", "0001")
    .attach(
      "arquivo",
      fs.readFileSync("examples/csv/outra_remuneracao.csv"),
      "outra_remuneracao.csv",
    )
    .expect(201);

  assert.equal(response.body.fileName, "1234562026070001.XTE");
  assert.equal(response.body.validation.isValid, true);
  assert.match(
    Buffer.from(response.body.contentBase64, "base64").toString("latin1"),
    /<outraRemuneracaoMonitoramento>/,
  );
});

test("API devolve 422 e detalhes por linha para CSV inválido", async () => {
  const response = await request(app)
    .post("/api/v1/monitoramento/gerar")
    .field("registro_ans", "123456")
    .field("competencia", "202607")
    .field("numero_lote", "LOTE0001")
    .field("sequencial_arquivo", "0001")
    .attach(
      "arquivo",
      Buffer.from("tipo_bloco;chave_registro;tipo_registro\noutra_remuneracao;R;1\n"),
      "invalido.csv",
    )
    .expect(422);

  assert.equal(response.body.code, "CSV_INVALIDO");
  assert.ok(response.body.details.length > 0);
});

test("API valida upload XTE e retorna encoding, XSD e hashes", async () => {
  const generated = await generateMonitoringFile({
    noMovement: true,
    metadata: {
      registroAns: "123456",
      competencia: "202607",
      numeroLote: "LOTE0001",
      sequencialArquivo: "0001",
    },
    now: new Date("2026-08-09T10:30:00-03:00"),
  });

  const response = await request(app)
    .post("/api/v1/monitoramento/validar")
    .attach("arquivo", generated.buffer, "monitoramento.XTE")
    .expect(200);

  assert.equal(response.body.isValid, true);
  assert.equal(response.body.encoding.isValid, true);
  assert.equal(response.body.xsd.isValid, true);
  assert.equal(response.body.hash.informed, generated.hash);
  assert.equal(response.body.hash.calculated, generated.hash);
});

test("API retorna 422 com hash informado e hash correto", async () => {
  const generated = await generateMonitoringFile({
    noMovement: true,
    metadata: {
      registroAns: "123456",
      competencia: "202607",
      numeroLote: "LOTE0001",
      sequencialArquivo: "0001",
    },
    now: new Date("2026-08-09T10:30:00-03:00"),
  });
  const informed = "0".repeat(32);
  const tampered = Buffer.from(generated.xml.replace(generated.hash, informed), "latin1");

  const response = await request(app)
    .post("/api/v1/monitoramento/validar")
    .attach("arquivo", tampered, "monitoramento.XTE")
    .expect(422);

  assert.equal(response.body.isValid, false);
  assert.equal(response.body.hash.informed, informed);
  assert.equal(response.body.hash.calculated, generated.hash);
});
