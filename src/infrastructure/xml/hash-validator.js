import crypto from "node:crypto";
import { create } from "xmlbuilder2";
import { assertLatin1 } from "../csv/normalizers.js";

export function validateMonitoringHash(xml) {
  try {
    const document = create(xml).node;
    const root = document.documentElement;
    const hashElements = root.getElementsByTagNameNS("*", "hash");
    const informed = hashElements.item(0)?.textContent ?? "";
    const content = concatenateLeafValues(root);
    assertLatin1(content, "conteudo_hash");
    const calculated = crypto
      .createHash("md5")
      .update(Buffer.from(content, "latin1"))
      .digest("hex")
      .toUpperCase();

    return {
      isValid: informed.toUpperCase() === calculated,
      informed,
      calculated,
      algorithm: "MD5",
      encoding: "ISO-8859-1",
    };
  } catch (error) {
    return {
      isValid: false,
      informed: "",
      calculated: "",
      algorithm: "MD5",
      encoding: "ISO-8859-1",
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
