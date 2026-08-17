import test from "node:test";
import assert from "node:assert/strict";
import { buildXteFileName, normalizeMetadata } from "../src/domain/monitoramento/metadata.js";

test("normaliza o cabeçalho e monta a nomenclatura oficial XTE", () => {
  const metadata = normalizeMetadata(
    {
      registroAns: "123456",
      competencia: "07/2026",
      numeroLote: "LOTE0001",
      sequencialArquivo: "7",
    },
    new Date("2026-08-09T10:30:00-03:00"),
  );

  assert.equal(metadata.competence, "202607");
  assert.equal(metadata.fileSequence, "0007");
  assert.equal(buildXteFileName(metadata), "1234562026070007.XTE");
});

test("rejeita competência com mês impossível", () => {
  assert.throws(
    () => normalizeMetadata({ registroAns: "123456", competencia: "202613", numeroLote: "1" }),
    /Parâmetros do cabeçalho inválidos/,
  );
});

test("rejeita data/hora de geração futura", () => {
  assert.throws(
    () =>
      normalizeMetadata(
        {
          registroAns: "123456",
          competencia: "202607",
          numeroLote: "1",
          dataRegistro: "2026-08-10",
          horaRegistro: "00:00:00",
        },
        new Date("2026-08-09T10:30:00-03:00"),
      ),
    /Parâmetros do cabeçalho inválidos/,
  );
});
