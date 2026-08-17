import crypto from "node:crypto";
import { create } from "xmlbuilder2";
import { assertLatin1 } from "../csv/normalizers.js";

export function validateMonitoringHash(xml) {
  try {
    const document = create(xml).node;
    const root = document.documentElement;
    const hashElements = root.getElementsByTagNameNS("*", "hash");
    const informed = (hashElements.item(0)?.textContent ?? "").trim();
    const content = concatenateLeafValues(root);
    assertLatin1(content, "conteudo_hash");
    const calculated = crypto
      .createHash("md5")
      .update(Buffer.from(content, "latin1"))
      .digest("hex")
      .toUpperCase();

    const hasSingleHash = hashElements.length === 1;
    const hasValidFormat = /^[A-F0-9]{32}$/i.test(informed);
    const isValid = hasSingleHash && hasValidFormat && informed.toUpperCase() === calculated;
    return {
      isValid,
      informed,
      calculated,
      algorithm: "MD5",
      encoding: "ISO-8859-1",
      hasValidFormat,
      message: isValid
        ? "O hash informado confere com o conteúdo do XML."
        : !hasSingleHash
          ? `O XML deve possuir exatamente um elemento hash; encontrados: ${hashElements.length}.`
          : !hasValidFormat
            ? "O hash informado deve conter 32 caracteres hexadecimais."
            : "O hash informado diverge do MD5 calculado para os valores do XML.",
    };
  } catch (error) {
    return {
      isValid: false,
      informed: "",
      calculated: "",
      algorithm: "MD5",
      encoding: "ISO-8859-1",
      hasValidFormat: false,
      message: `Não foi possível calcular o hash: ${error.message}`,
      error: error.message,
    };
  }
}

function concatenateLeafValues(element) {
  if (element.localName === "epilogo") return "";
  const childElements = [...element.childNodes].filter((node) => node.nodeType === 1);
  if (childElements.length === 0) return element.textContent ?? "";
  return childElements.map(concatenateLeafValues).join("");
}
