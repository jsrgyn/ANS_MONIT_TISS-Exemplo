import { validateMonitoringHash } from "../infrastructure/xml/hash-validator.js";
import { validateXmlAgainstAnsSchema } from "../infrastructure/xml/xsd-validator.js";

export async function validateMonitoringFile(xml) {
  const [xsd, hash] = await Promise.all([
    validateXmlAgainstAnsSchema(xml),
    Promise.resolve(validateMonitoringHash(xml)),
  ]);
  return { isValid: xsd.isValid && hash.isValid, xsd, hash };
}
