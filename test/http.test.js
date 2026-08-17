import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import request from "supertest";
import { createApp } from "../src/interfaces/http/app.js";

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
