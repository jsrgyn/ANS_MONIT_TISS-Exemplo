import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { parseMonitoringCsv } from "../src/infrastructure/csv/parse-monitoring-csv.js";

test("importa o CSV de custo médico e agrupa procedimentos por chave", () => {
  const result = parseMonitoringCsv(fs.readFileSync("examples/csv/guia_monitoramento.csv"));
  assert.equal(result.blockType, "guia");
  assert.equal(result.rowsRead, 3);
  assert.equal(result.records.length, 2);
  assert.equal(result.records[0].items.length, 2);
  assert.equal(result.records[0].valor_total_informado, "250.00");
  assert.equal(result.records[1].items[0].sourceLine, 4);
});

test("informa linha, coluna e campo para valor fora do domínio do XSD", () => {
  const source = fs
    .readFileSync("arq_exemplo/guia_monitoramento_custo_medico.csv", "utf8")
    .replaceAll(";3;1234567;", ";9;1234567;")
    .replace(";3;7654321;", ";9;7654321;");

  assert.throws(
    () => parseMonitoringCsv(Buffer.from(source)),
    (error) =>
      error.code === "CSV_INVALIDO" &&
      error.details.some(
        (item) =>
          item.linha === 2 &&
          item.coluna === 5 &&
          item.campo === "forma_envio" &&
          item.localizacao === "L2:C5",
      ),
  );
});

test("rejeita coluna desconhecida para localizar erros de cabeçalho", () => {
  const source = fs
    .readFileSync("examples/csv/outra_remuneracao.csv", "utf8")
    .replace(";valor_total_pago", ";valor_total_pago;coluna_com_erro")
    .replace(";1500.00\n", ";1500.00;X\n");

  assert.throws(
    () => parseMonitoringCsv(Buffer.from(source)),
    (error) =>
      error.code === "CSV_INVALIDO" &&
      error.details.some(
        (item) => item.linha === 1 && item.coluna === 10 && item.campo === "coluna_com_erro",
      ),
  );
});

test("valida listas estruturadas antes de gerar o XML", () => {
  const lines = fs
    .readFileSync("arq_exemplo/guia_monitoramento_custo_medico.csv", "utf8")
    .trimEnd()
    .split("\n");
  const fieldIndex = lines[0].split(";").indexOf("formas_remuneracao");
  const values = lines[1].split(";");
  values[fieldIndex] = "99:ABC";
  lines[1] = values.join(";");

  assert.throws(
    () => parseMonitoringCsv(Buffer.from(lines.join("\n"))),
    (error) =>
      error.code === "CSV_INVALIDO" &&
      error.details.some((item) => item.linha === 2 && item.campo === "formas_remuneracao"),
  );
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
