// Se ejecuta contra el frontend WASM instalado por el build real del consumidor.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const [wasmPath, mainPath] = process.argv.slice(2);
if (!mainPath) throw new Error("Uso: frontend_test.mjs <frontend.wasm> <main.js>");
const bytes = await readFile(wasmPath);
const mainSource = await readFile(mainPath, "utf8");

async function frontend() {
    const sent = [];
    let exports;
    const read = (ptr, len) => new TextDecoder().decode(new Uint8Array(exports.memory.buffer, ptr, len));
    const result = await WebAssembly.instantiate(bytes, {
        env: { js_send_post(ptr, len) { sent.push(read(ptr, len)); } },
    });
    exports = result.instance.exports;
    const entities = JSON.parse(read(exports.schema_ptr(), exports.schema_len()));
    return {
        entities, sent,
        row: () => JSON.parse(read(exports.json_ptr(), exports.json_len())),
        error: () => read(exports.error_ptr(), exports.error_len()),
        create(name, values) {
            const index = entities.findIndex((entity) => entity.name === name);
            assert.notEqual(index, -1);
            const parts = entities[index].fields.map((field) => new TextEncoder().encode(values[field.name] ?? ""));
            const memory = new Uint8Array(exports.memory.buffer);
            assert.ok(parts.reduce((total, part) => total + part.length, 0) <= exports.input_len());
            const lengths = new Uint32Array(exports.memory.buffer, exports.lengths_ptr(), parts.length);
            let offset = exports.input_ptr();
            parts.forEach((part, i) => { memory.set(part, offset); lengths[i] = part.length; offset += part.length; });
            return exports.create_row(index);
        },
    };
}

test("el catálogo contiene las ocho entidades del supermercado y ninguna de AIDA", async () => {
    const app = await frontend();
    assert.deepEqual(app.entities.map((entity) => entity.name), [
        "productos", "productos_precios", "clientes", "carritos", "productos_carritos",
        "descuentos_cantidad", "tickets", "tickets_productos",
    ]);
    const prices = app.entities.find((entity) => entity.name === "productos_precios");
    const amount = prices.fields.find((field) => field.name === "precio");
    assert.equal(amount.type, "importe");
    assert.equal(amount.storage, "integer");
    assert.equal(amount.nullable, false);
    assert.equal(prices.fields.find((field) => field.name === "vigencia_desde").storage, "text");
});

test("el catálogo conserva las claves compuestas y las referencias opcionales", async () => {
    const app = await frontend();
    const detail = app.entities.find((entity) => entity.name === "productos_carritos");
    assert.deepEqual(detail.pk, ["id_carrito", "id_producto"]);
    assert.deepEqual(detail.fks.precio, {
        entity: "productos_precios", fields: { id_producto: "id_producto", id_precio: "id" },
    });
    assert.equal(detail.fields.find((field) => field.name === "id_descuento").nullable, true);
    for (const name of ["carritos", "tickets"]) {
        assert.equal(app.entities.find((entity) => entity.name === name).fields.find((field) => field.name === "id_cliente").nullable, true);
    }
});

test("el frontend conserva centavos enteros e instantes UTC sin convertirlos a objetos de fecha", async () => {
    const app = await frontend();
    assert.ok(app.create("productos_precios", {
        id: "1", id_producto: "2", vigencia_desde: "2026-11-12T12:30:00.120Z", precio: "199",
    }) > 0);
    assert.deepEqual(JSON.parse(app.sent[0]), {
        id: 1, id_producto: 2, vigencia_desde: "2026-11-12T12:30:00.120Z", precio: 199,
    });
});

test("el frontend rechaza importes fraccionarios y componentes vacíos de la clave antes de enviar", async () => {
    const app = await frontend();
    assert.equal(app.create("productos_precios", {
        id: "1", id_producto: "2", vigencia_desde: "2026-11-12T12:30:00.120Z", precio: "1.99",
    }), 0);
    for (const field of ["id_carrito", "id_producto"]) {
        assert.equal(app.create("productos_carritos", { id_carrito: "1", id_producto: "2", cantidad: "3", id_precio: "4", [field]: "" }), 0);
        assert.match(app.error(), new RegExp(field));
    }
    assert.equal(app.sent.length, 0);
});

test("el cliente anónimo y la promoción ausente son null y una promoción inactiva conserva false", async () => {
    const app = await frontend();
    assert.ok(app.create("carritos", { id: "1", fecha_inicio: "2026-11-12T12:30:00.120Z", estado: "abierto" }) > 0);
    assert.equal(app.row().id_cliente, null);
    assert.ok(app.create("productos_carritos", { id_carrito: "1", id_producto: "2", cantidad: "3", id_precio: "4" }) > 0);
    assert.equal(app.row().id_descuento, null);
    assert.ok(app.create("descuentos_cantidad", {
        id: "1", id_producto: "2", vigencia_desde: "2026-11-12T12:30:00.120Z", cantidad_llevar: "3", descuento_porcentaje: "10", activo: "false",
    }) > 0);
    assert.equal(app.row().activo, false);
});

test("el cliente JS usa ambas claves para identificar el renglón y las excluye del PUT", async () => {
    const app = await frontend();
    const entity = app.entities.find((entry) => entry.name === "productos_carritos");
    const context = vm.createContext({
        TextEncoder, TextDecoder, console, URLSearchParams,
        document: { getElementById: () => ({ addEventListener() {} }) },
        fixtureEntity: entity,
    });
    new vm.Script(mainSource, { filename: mainPath, importModuleDynamically: () => new Promise(() => {}) }).runInContext(context);
    vm.runInContext("currentEntity = fixtureEntity", context);
    const body = JSON.stringify({ id_carrito: 1, id_producto: 2, cantidad: 3, id_precio: 4, id_descuento: null });
    context.fixtureBody = body;
    const put = vm.runInContext("restBodyFromRowJson(fixtureEntity, fixtureBody, { omitPk: true })", context);
    assert.deepEqual(JSON.parse(put), { cantidad: 3, id_precio: 4, id_descuento: null });
    const url = vm.runInContext("resourceUrl(fixtureEntity, { id_carrito: 1, id_producto: 2 })", context);
    assert.match(url, /productos_carritos\?id_carrito=1&id_producto=2$/);
});
