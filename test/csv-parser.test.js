import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { parseMonitoringCsv } from "../src/infrastructure/csv/parse-monitoring-csv.js";

test("agrupa duas linhas de procedimento em uma guia", () => {
  const result = parseMonitoringCsv(fs.readFileSync("examples/csv/guia_monitoramento.csv"));
  assert.equal(result.blockType, "guia");
  assert.equal(result.rowsRead, 2);
  assert.equal(result.records.length, 1);
  assert.equal(result.records[0].items.length, 2);
  assert.equal(result.records[0].valor_total_informado, "150.00");
});

test("informa linha e campo para valor obrigatório vazio", () => {
  const csv = Buffer.from(
    "tipo_bloco;chave_registro;tipo_registro;data_processamento;recebedor_tipo_identificacao;recebedor_cpf_cnpj;valor_total_informado;valor_total_glosa;valor_total_pago\n" +
      "outra_remuneracao;R1;1;2026-07-31;1;12345678000195;;0;10\n",
  );
  assert.throws(
    () => parseMonitoringCsv(csv),
    (error) =>
      error.code === "CSV_INVALIDO" &&
      error.details.some((item) => item.linha === 2 && item.campo === "valor_total_informado"),
  );
});

test("rejeita tipos de bloco misturados no mesmo arquivo", () => {
  const csv = Buffer.from(
    "tipo_bloco;chave_registro;tipo_registro\nguia;A;1\noutra_remuneracao;B;1\n",
  );
  assert.throws(() => parseMonitoringCsv(csv), /exatamente um tipo de bloco/);
});
