export function isValidCpf(value) {
  const cpf = String(value ?? "");
  if (!/^\d{11}$/.test(cpf) || /^(\d)\1{10}$/.test(cpf)) return false;
  const first = calculateCpfDigit(cpf.slice(0, 9), 10);
  const second = calculateCpfDigit(`${cpf.slice(0, 9)}${first}`, 11);
  return cpf.endsWith(`${first}${second}`);
}

export function isValidCnpj(value) {
  const cnpj = String(value ?? "").toUpperCase();
  if (!/^[A-Z0-9]{12}\d{2}$/.test(cnpj) || /^(\d)\1{13}$/.test(cnpj)) return false;
  const base = cnpj.slice(0, 12);
  const first = calculateCnpjDigit(base);
  const second = calculateCnpjDigit(`${base}${first}`);
  return cnpj.endsWith(`${first}${second}`);
}

function calculateCpfDigit(base, initialWeight) {
  const total = [...base].reduce(
    (sum, digit, index) => sum + Number(digit) * (initialWeight - index),
    0,
  );
  const remainder = total % 11;
  return remainder < 2 ? 0 : 11 - remainder;
}

function calculateCnpjDigit(base) {
  let weight = base.length - 7;
  const total = [...base].reduce((sum, character) => {
    const result = sum + (character.charCodeAt(0) - 48) * weight;
    weight -= 1;
    if (weight === 1) weight = 9;
    return result;
  }, 0);
  const remainder = total % 11;
  return remainder < 2 ? 0 : 11 - remainder;
}
