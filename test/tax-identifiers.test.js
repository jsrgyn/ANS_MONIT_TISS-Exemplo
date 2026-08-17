import test from "node:test";
import assert from "node:assert/strict";
import { isValidCnpj, isValidCpf } from "../src/domain/monitoramento/tax-identifiers.js";

test("valida CPF e CNPJ numérico pelos dígitos verificadores", () => {
  assert.equal(isValidCpf("52998224725"), true);
  assert.equal(isValidCpf("52998224724"), false);
  assert.equal(isValidCnpj("12345678000195"), true);
  assert.equal(isValidCnpj("12345678000194"), false);
});

test("valida CNPJ alfanumérico pelo módulo 11 da Receita Federal", () => {
  assert.equal(isValidCnpj("12ABC34501DE35"), true);
  assert.equal(isValidCnpj("12ABC34501DE34"), false);
});
