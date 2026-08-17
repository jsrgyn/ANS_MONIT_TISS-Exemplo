const generatorForm = document.querySelector("#generator-form");
const validatorForm = document.querySelector("#validator-form");
const noMovement = document.querySelector("#no-movement");
const csvFile = document.querySelector("#csv-file");
const log = document.querySelector("#log");
const download = document.querySelector("#download");

noMovement.addEventListener("change", () => {
  csvFile.disabled = noMovement.checked;
  csvFile.required = !noMovement.checked;
});

generatorForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const payload = new FormData(generatorForm);
  setBusy(generatorForm, true);
  show("Processando CSV, gerando XML e validando no XSD oficial...");
  download.hidden = true;

  try {
    const response = await fetch("/api/v1/monitoramento/gerar", {
      method: "POST",
      body: payload,
    });
    const data = await response.json();
    if (!response.ok) throw apiError(data);

    const bytes = Uint8Array.from(atob(data.contentBase64), (character) => character.charCodeAt(0));
    const url = URL.createObjectURL(new Blob([bytes], { type: "application/xml" }));
    download.href = url;
    download.download = data.fileName;
    download.hidden = false;
    show(
      [
        "[OK] XML válido conforme o schema ANS 01.06.00",
        `[OK] Arquivo: ${data.fileName}`,
        `[OK] Bloco: ${data.blockType}`,
        `[OK] ${data.recordCount} registro(s), ${data.rowsRead} linha(s) CSV`,
        `[OK] Hash MD5: ${data.hash}`,
        "[OK] Encoding de saída: ISO-8859-1",
        `[INFO] Motor: ${data.validation.engine}`,
      ].join("\n"),
    );
  } catch (error) {
    show(`[ERRO] ${error.message}\n${formatDetails(error.details)}`);
  } finally {
    setBusy(generatorForm, false);
  }
});

validatorForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const payload = new FormData(validatorForm);
  setBusy(validatorForm, true);
  show("Validando encoding, estrutura XSD e hash MD5...");
  try {
    const response = await fetch("/api/v1/monitoramento/validar", {
      method: "POST",
      body: payload,
    });
    const data = await response.json();
    if (!response.ok && !data.xsd) throw apiError(data);

    const lines = [
      data.encoding.isValid
        ? `[OK] Encoding ${data.encoding.expected}`
        : `[ERRO] Encoding incompatível: declarado=${data.encoding.declared}, esperado=${data.encoding.expected}`,
      data.xsd.isValid ? "[OK] XML válido no XSD 01.06.00" : "[ERRO] XML inválido no XSD 01.06.00",
      data.hash.isValid
        ? `[OK] Hash MD5 confere: ${data.hash.calculated}`
        : `[ERRO] Hash divergente: informado=${data.hash.informed || "ausente"}, calculado=${data.hash.calculated || "indisponível"}`,
      ...(data.encoding.errors ?? []).map((error) => error.formatted),
      ...(data.xsd.errors ?? []).map((error) => error.formatted),
    ];
    show(lines.join("\n"));
  } catch (error) {
    show(`[ERRO] ${error.message}\n${formatDetails(error.details)}`);
  } finally {
    setBusy(validatorForm, false);
  }
});

function setBusy(form, busy) {
  for (const element of form.elements) element.disabled = busy;
  if (!busy) noMovement.dispatchEvent(new Event("change"));
}

function show(message) {
  log.textContent = message;
}

function apiError(data) {
  const error = new Error(data.message ?? "Falha na requisição.");
  error.details = data.details;
  return error;
}

function formatDetails(details = []) {
  return details
    .map(
      (item) =>
        `- ${item.localizacao ?? `L${item.linha ?? "?"}:C${item.coluna ?? "?"}`} — ${item.campo ?? "-"}: ${item.mensagem ?? item.message}`,
    )
    .join("\n");
}
