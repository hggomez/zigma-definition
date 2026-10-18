// Ejecuta el WASM de producción. Los controles escalares usan un DOM mínimo;
// la interacción completa y los objetos genéricos se comprueban también en navegador.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import { pathToFileURL } from "node:url";

const [wasmPath, oversizedPath, mainPath, widgetsPath] = process.argv.slice(2);
if (!widgetsPath) throw new Error("Uso: run_frontend_test.mjs <wasm> <wasm-grande> <main.js> <widgets.js>");
const wasmBytes = await readFile(wasmPath);
const oversizedBytes = await readFile(oversizedPath);
const mainSource = await readFile(mainPath, "utf8");
const { widgets: aidaWidgets } = await import(pathToFileURL(widgetsPath).href);

async function frontend(bytes = wasmBytes) {
    const sent = [];
    let exports;
    const result = await WebAssembly.instantiate(bytes, { env: {
        js_send_post(ptr, len) { sent.push(read(ptr, len)); },
    } });
    exports = result.instance.exports;
    function read(ptr, len) {
        return new TextDecoder().decode(new Uint8Array(exports.memory.buffer, ptr, len));
    }
    function catalogue() {
        const len = exports.schema_len();
        return JSON.parse(read(exports.schema_ptr(), len));
    }
    function pack(entityName, values) {
        const entities = catalogue();
        const index = entities.findIndex((entity) => entity.name === entityName);
        assert.notEqual(index, -1, `Entidad desconocida: ${entityName}`);
        const parts = entities[index].fields.map((field) => new TextEncoder().encode(values[field.name] ?? ""));
        assert.ok(parts.reduce((size, part) => size + part.length, 0) <= exports.input_len());
        const memory = new Uint8Array(exports.memory.buffer);
        const lengths = new Uint32Array(exports.memory.buffer, exports.lengths_ptr(), parts.length);
        let offset = exports.input_ptr();
        parts.forEach((part, i) => {
            memory.set(part, offset);
            lengths[i] = part.length;
            offset += part.length;
        });
        return index;
    }
    return {
        exports, sent, read, catalogue, pack,
        error: () => read(exports.error_ptr(), exports.error_len()),
        row: () => JSON.parse(read(exports.json_ptr(), exports.json_len())),
        build(name, values, create = false) {
            const index = pack(name, values);
            return create ? exports.create_row(index) : exports.build_row(index);
        },
    };
}

// Solo implementa los elementos que necesitan makeInput y readFieldValue para
// controles escalares. No reemplaza las pruebas de navegador de la página completa.
function element(tagName) {
    return {
        tagName: tagName.toUpperCase(), dataset: {}, children: [], value: "", checked: false,
        disabled: false, type: "", textContent: "",
        appendChild(child) { this.children.push(child); return child; },
        setAttribute(name, value) { this[name] = value; },
        addEventListener() {},
    };
}

function ui(entity, widgets = {}) {
    const context = vm.createContext({
        TextEncoder, TextDecoder, console, URLSearchParams,
        document: { getElementById: () => ({ addEventListener() {} }), createElement: element },
        fixtureEntity: entity, fixtureWidgets: widgets,
    });
    // Deja pendiente el arranque remoto; las pruebas llaman a los controles reales.
    new vm.Script(mainSource, {
        filename: mainPath,
        importModuleDynamically: () => new Promise(() => {}),
    }).runInContext(context);
    vm.runInContext("currentEntity = fixtureEntity; widgets = fixtureWidgets;", context);
    return context;
}

const rootFor = (control) => ({ querySelector: () => control });
const plain = (value) => JSON.parse(JSON.stringify(value));

test("el catálogo AIDA expone nulabilidad efectiva y mantiene orden y relaciones", async () => {
    const app = await frontend();
    const entities = app.catalogue();
    assert.equal(entities[0].name, "docentes");
    for (const entity of entities) {
        for (const field of entity.fields) {
            assert.equal(typeof field.nullable, "boolean", `${entity.name}.${field.name}`);
            if (entity.pk.includes(field.name)) assert.equal(field.nullable, false);
        }
    }
    const docentes = entities.find((entity) => entity.name === "docentes");
    assert.deepEqual(docentes.fks.jefe, { entity: "docentes", fields: { jefe: "docente" } });
    assert.equal(docentes.fields.find((field) => field.name === "experiencia").nullable, true);
    const mesas = entities.find((entity) => entity.name === "mesas");
    assert.deepEqual(mesas.pk, ["periodo", "materia", "fecha"]);
});

test("POST rechaza PK vacía antes de enviar y permite recuperarse", async () => {
    const app = await frontend();
    assert.equal(app.build("materias", { materia: "", denominacion: "Nombre" }, true), 0);
    assert.equal(app.sent.length, 0);
    assert.equal(app.exports.json_len(), 0);
    assert.match(app.error(), /materia/);
    assert.ok(app.build("materias", { materia: "OK", denominacion: "Nombre" }, true) > 0);
    assert.equal(app.sent.length, 1);
    assert.deepEqual(JSON.parse(app.sent[0]), { materia: "OK", denominacion: "Nombre" });
    assert.equal(app.exports.error_len(), 0);
});

test("una PK compuesta rechaza cada componente vacío", async () => {
    const app = await frontend();
    for (const missing of ["periodo", "materia"]) {
        assert.equal(app.build("cursos", { periodo: "P", materia: "M", docente: "", [missing]: "" }, true), 0);
        assert.match(app.error(), new RegExp(missing));
    }
    assert.equal(app.sent.length, 0);
});

test("opcionales vacíos son null; false, cero y el texto null permanecen presentes", async () => {
    const app = await frontend();
    assert.ok(app.build("docentes", { docente: "D", nombres: "Nombre" }) > 0);
    for (const name of ["telefono", "experiencia", "esImportador"]) assert.equal(app.row()[name], null);
    assert.ok(app.build("docentes", {
        docente: "D", nombres: "Nombre", telefono: "null", experiencia: "0", esImportador: "false",
    }) > 0);
    assert.equal(app.row().telefono, "null");
    assert.equal(app.row().experiencia, 0);
    assert.equal(app.row().esImportador, false);
});

test("WASM conserva Fecha como objeto y admite null cuando no es PK", async () => {
    const app = await frontend();
    const identity = { periodo: "P", materia: "M", orden: "1" };
    assert.ok(app.build("clases", { ...identity, fecha: "" }) > 0);
    assert.equal(app.row().fecha, null);
    const date = { año: 2024, mes: 2, día: 29 };
    assert.ok(app.build("clases", { ...identity, fecha: JSON.stringify(date) }) > 0);
    assert.deepEqual(app.row().fecha, date);
});

test("el JSON del WASM escapa texto sin modificar su valor", async () => {
    const app = await frontend();
    const text = 'Profesor "Juan"\\aula\nsegunda línea\tñ 😀';
    assert.ok(app.build("materias", { materia: "M", denominacion: text }, true) > 0);
    assert.deepEqual(JSON.parse(app.sent[0]), { materia: "M", denominacion: text });
});

test("un error de valor invalida el JSON anterior y no envía otra solicitud", async () => {
    const app = await frontend();
    assert.ok(app.build("docentes", { docente: "D", nombres: "N", experiencia: "1" }, true) > 0);
    assert.equal(app.build("docentes", { docente: "D", nombres: "N", experiencia: "abc" }, true), 0);
    assert.equal(app.exports.json_len(), 0);
    assert.equal(app.sent.length, 1);
    assert.match(app.error(), /experiencia/);
});

test("una entidad desconocida invalida el JSON anterior", async () => {
    const app = await frontend();
    assert.ok(app.build("materias", { materia: "M", denominacion: "N" }) > 0);
    assert.equal(app.exports.create_row(0xffffffff), 0);
    assert.equal(app.exports.json_len(), 0);
    assert.equal(app.sent.length, 0);
    assert.ok(app.error().length > 0);
});

test("longitudes que exceden la entrada se rechazan sin reutilizar JSON", async () => {
    const app = await frontend();
    assert.ok(app.build("materias", { materia: "M", denominacion: "N" }) > 0);
    const index = app.pack("materias", { materia: "M", denominacion: "N" });
    new Uint32Array(app.exports.memory.buffer, app.exports.lengths_ptr(), 2)[0] = app.exports.input_len() + 1;
    assert.equal(app.exports.create_row(index), 0);
    assert.equal(app.exports.json_len(), 0);
    assert.equal(app.sent.length, 0);
    assert.ok(app.error().length > 0);
});

test("el desbordamiento de salida no envía JSON parcial y permite recuperarse", async () => {
    const app = await frontend();
    assert.ok(app.build("materias", { materia: "M", denominacion: "N" }, true) > 0);
    const text = "x".repeat(app.exports.input_len() - 2);
    assert.equal(app.build("materias", { materia: "M", denominacion: text }, true), 0);
    assert.equal(app.exports.json_len(), 0);
    assert.equal(app.sent.length, 1);
    assert.ok(app.error().length > 0);
    assert.ok(app.build("materias", { materia: "M", denominacion: "Recuperado" }, true) > 0);
    assert.equal(app.sent.length, 2);
    assert.equal(JSON.parse(app.sent[1]).denominacion, "Recuperado");
    assert.equal(app.exports.error_len(), 0);
});

test("la expansión por escapes también respeta el límite de salida", async () => {
    const app = await frontend();
    assert.equal(app.build("materias", { materia: "M", denominacion: "\n".repeat(5000) }, true), 0);
    assert.equal(app.exports.json_len(), 0);
    assert.equal(app.sent.length, 0);
    assert.ok(app.error().length > 0);
});

test("un catálogo demasiado grande usa el canal de errores y no provoca un trap", async () => {
    const app = await frontend(oversizedBytes);
    assert.doesNotThrow(() => assert.equal(app.exports.schema_len(), 0));
    assert.ok(app.error().length > 0);
    assert.doesNotThrow(() => app.exports.schema_ptr());
    assert.equal(app.exports.schema_len(), 0);
    assert.equal(app.sent.length, 0);
});

test("booleano nullable ofrece Sin valor, Sí y No sin convertir null en false", () => {
    const field = { name: "flag", type: "boolean", storage: "boolean", nullable: true };
    const view = ui({ fields: [field], pk: [], fks: {} });
    const control = view.makeInput(field, null, false);
    assert.equal(control.tagName, "SELECT");
    assert.deepEqual(control.children.map((option) => [option.value, option.textContent]), [
        ["", "Sin valor"], ["true", "Sí"], ["false", "No"],
    ]);
    for (const value of ["", "true", "false"]) {
        control.value = value;
        assert.equal(view.readFieldValue(rootFor(control), field), value);
    }
    assert.equal(view.makeInput(field, false, false).value, "false");
    assert.equal(view.makeInput(field, true, false).value, "true");
    assert.equal(view.makeInput(field, false, true).disabled, true);
});

test("booleano obligatorio conserva el checkbox", () => {
    const field = { name: "flag", type: "boolean", storage: "boolean", nullable: false };
    const view = ui({ fields: [field], pk: [], fks: {} });
    const control = view.makeInput(field, false, false);
    assert.equal(control.type, "checkbox");
    assert.equal(view.readFieldValue(rootFor(control), field), "false");
    control.checked = true;
    assert.equal(view.readFieldValue(rootFor(control), field), "true");
});

test("editar texto conserva el booleano null de una fila cargada", async () => {
    const app = await frontend();
    const entity = app.catalogue().find((item) => item.name === "docentes");
    const view = ui(entity);
    const loaded = { docente: "D", nombres: "Antes", esImportador: null };
    const controls = entity.fields.map((field) => view.makeInput(field, loaded[field.name] ?? null, entity.pk.includes(field.name)));
    controls[entity.fields.findIndex((field) => field.name === "nombres")].value = "Después";
    const cells = Object.fromEntries(entity.fields.map((field, i) => [field.name, view.readFieldValue(rootFor(controls[i]), field)]));
    assert.ok(app.build("docentes", cells) > 0);
    const body = JSON.parse(view.restBodyFromRowJson(entity, JSON.stringify(app.row()), { omitPk: true }));
    assert.equal(body.nombres, "Después");
    assert.equal(body.esImportador, null);
    assert.equal(Object.hasOwn(body, "docente"), false);
});

test("el widget Fecha vacío devuelve null y una fecha conserva su objeto público", () => {
    const field = { name: "fecha", type: "fecha", storage: "object", nullable: true };
    assert.equal(aidaWidgets.fecha.read(rootFor({ value: "" }), field), null);
    assert.deepEqual(aidaWidgets.fecha.read(rootFor({ value: "2024-02-29" }), field), { año: 2024, mes: 2, día: 29 });
});

test("un widget que devuelve null se empaqueta como celda vacía", () => {
    const field = { name: "fecha", type: "fecha", storage: "object", nullable: true };
    const view = ui({ fields: [field], pk: [], fks: {} }, { fecha: { read: () => null } });
    assert.equal(view.readFieldValue(rootFor({}), field), "");
});

test("mostrar valores null no inventa false ni objetos vacíos", () => {
    const view = ui({ fields: [], pk: [], fks: {} });
    for (const storage of ["text", "integer", "boolean", "object"]) assert.equal(view.cellString({ storage }, null), "");
    assert.equal(view.cellString({ storage: "boolean" }, false), "false");
    assert.equal(view.cellString({ storage: "integer" }, 0), "0");
});

test("POST conserva la fila y PUT solo excluye las PK, incluso compuestas", () => {
    const entity = { fields: [], pk: ["periodo", "materia"], fks: {} };
    const view = ui(entity);
    const row = { periodo: "P", materia: "M", docente: null, texto: 'Nombre "visible"' };
    assert.deepEqual(plain(JSON.parse(view.restBodyFromRowJson(entity, JSON.stringify(row), { omitPk: false }))), row);
    assert.deepEqual(plain(JSON.parse(view.restBodyFromRowJson(entity, JSON.stringify(row), { omitPk: true }))), {
        docente: null, texto: 'Nombre "visible"',
    });
});
