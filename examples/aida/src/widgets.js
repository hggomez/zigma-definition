// Consumer widgets: domain type name → `{ make, read }`.
// `make` returns a cell control; `read` returns the JS value packed for WASM
// (objects are JSON.stringified by main.js). Unknown types fall back to storage.

function fechaToIso(value) {
    if (!value || value["año"] == null || value.mes == null || value["día"] == null) return "";
    const y = String(value["año"]).padStart(4, "0");
    const m = String(value.mes).padStart(2, "0");
    const d = String(value["día"]).padStart(2, "0");
    return `${y}-${m}-${d}`;
}

function isoToFecha(iso) {
    const [y, m, d] = iso.split("-").map(Number);
    return { año: y, mes: m, día: d };
}

export const widgets = {
    fecha: {
        make(field, value, locked) {
            const input = document.createElement("input");
            input.type = "date";
            input.dataset.field = field.name;
            input.autocomplete = "off";
            input.value = fechaToIso(value);
            if (locked) {
                input.disabled = true;
                input.tabIndex = -1;
            }
            return input;
        },
        read(root, field) {
            const input = root.querySelector(`input[data-field="${field.name}"]`);
            if (!input?.value) return {};
            return isoToFecha(input.value);
        },
    },
};
