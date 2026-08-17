export class AppError extends Error {
  constructor(message, { statusCode = 400, code = "APP_ERROR", details = [] } = {}) {
    super(message);
    this.name = this.constructor.name;
    this.statusCode = statusCode;
    this.code = code;
    this.details = details;
  }
}

export class CsvValidationError extends AppError {
  constructor(message, details) {
    super(message, { statusCode: 422, code: "CSV_INVALIDO", details });
  }
}

export class XmlValidationError extends AppError {
  constructor(message, details) {
    super(message, { statusCode: 422, code: "XML_INVALIDO", details });
  }
}
