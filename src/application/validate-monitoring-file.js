import { validateMonitoringHash } from "../infrastructure/xml/hash-validator.js";
import { validateXmlAgainstAnsSchema } from "../infrastructure/xml/xsd-validator.js";
import { decodeMonitoringXml } from "../infrastructure/xml/xml-decoder.js";

export async function validateMonitoringFile(input) {
  const decoded = decodeMonitoringXml(input);
  const xml = decoded.xml;
  const [xsd, hash] = await Promise.all([
    validateXmlAgainstAnsSchema(xml),
    Promise.resolve(validateMonitoringHash(xml)),
  ]);
  return {
    isValid: decoded.validation.isValid && xsd.isValid && hash.isValid,
    encoding: decoded.validation,
    xsd,
    hash,
  };
}
