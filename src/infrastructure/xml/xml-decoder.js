import { findNonLatin1Character } from "../csv/normalizers.js";

const EXPECTED_ENCODING = "ISO-8859-1";
const UTF8_BOM = Buffer.from([0xef, 0xbb, 0xbf]);

export function decodeMonitoringXml(input) {
  const buffer = Buffer.isBuffer(input) || input instanceof Uint8Array ? Buffer.from(input) : null;
  const hasUtf8Bom = Boolean(buffer?.subarray(0, 3).equals(UTF8_BOM));
  const prefix = buffer
    ? buffer.subarray(0, 300).toString("latin1")
    : String(input ?? "").slice(0, 300);
  let declared = extractDeclaredEncoding(prefix);
  const errors = [];
  let xml = String(input ?? "");
  let detected = "texto já decodificado";

  if (buffer) {
    const declaresUtf8 = /^UTF-?8$/i.test(declared);
    if (hasUtf8Bom || declaresUtf8) {
      detected = hasUtf8Bom ? "UTF-8 com BOM" : "UTF-8 declarado";
      try {
        xml = new TextDecoder("utf-8", { fatal: true }).decode(
          hasUtf8Bom ? buffer.subarray(3) : buffer,
        );
      } catch {
        xml = buffer.toString("utf8");
        errors.push(encodingError("Os bytes não formam um documento UTF-8 válido."));
      }
    } else {
      detected = "ISO-8859-1 conforme a declaração";
      xml = buffer.toString("latin1");
    }
    declared = extractDeclaredEncoding(xml.slice(0, 300)) || declared;
  }

  if (!declared) {
    errors.push(
      encodingError(
        `Declaração XML sem encoding. O Monitoramento TISS deve declarar ${EXPECTED_ENCODING}.`,
      ),
    );
  } else if (declared.toUpperCase() !== EXPECTED_ENCODING) {
    errors.push(
      encodingError(
        `Encoding declarado '${declared}' é incompatível; use ${EXPECTED_ENCODING} no arquivo XTE.`,
      ),
    );
  }

  if (hasUtf8Bom) {
    errors.push(
      encodingError(
        `BOM UTF-8 encontrado; o arquivo XTE deve ser gravado em ${EXPECTED_ENCODING}.`,
      ),
    );
  }

  const invalidCharacter = findNonLatin1Character(xml);
  if (invalidCharacter) {
    errors.push(
      encodingError(
        `O caractere '${invalidCharacter}' não pode ser representado em ${EXPECTED_ENCODING}.`,
      ),
    );
  }

  return {
    xml,
    validation: {
      isValid: errors.length === 0,
      expected: EXPECTED_ENCODING,
      declared: declared || "ausente",
      detected,
      hasBom: hasUtf8Bom,
      errors,
    },
  };
}

function extractDeclaredEncoding(value) {
  return /<\?xml[^>]*\bencoding\s*=\s*["']([^"']+)["']/i.exec(String(value))?.[1]?.trim() ?? "";
}

function encodingError(message) {
  return {
    line: 1,
    column: 0,
    message,
    formatted: `[ENCODING] Linha 1: ${message}`,
  };
}
