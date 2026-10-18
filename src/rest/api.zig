//! CRUD REST derivados de entidades Zigma en compilación.
//!
//! Este módulo se ocupa del routing, validación de solicitudes y mapping de dominio.
//! No posee conocimiento sobre Web Sockets ni PostgreSQL;

const std = @import("std");
const domain_codecs = @import("codecs.zig");
const requests = @import("request.zig");
const responses = @import("response.zig");
const validation = @import("validation.zig");
const types = @import("types.zig");

pub const CodecError = domain_codecs.CodecError;
pub const Codec = domain_codecs.Codec;
pub const text_codec = domain_codecs.text_codec;
pub const integer_codec = domain_codecs.integer_codec;
pub const boolean_codec = domain_codecs.boolean_codec;
pub const common_codecs = domain_codecs.common_codecs;
pub const defineCodecs = domain_codecs.defineCodecs;

pub const Method = types.Method;
pub const Request = types.Request;
pub const Response = types.Response;
pub const Route = types.Route;
pub const FieldValue = types.FieldValue;
pub const QueryResult = types.QueryResult;
pub const RepositoryError = types.RepositoryError;
pub const Config = types.Config;

pub const BusinessRuleViolation = validation.BusinessRuleViolation;
pub const BusinessValidator = validation.BusinessValidator;
pub const defineBusinessValidators = validation.defineBusinessValidators;

fn routeList(comptime entity_defs: anytype) [@typeInfo(@TypeOf(entity_defs)).@"struct".field_names.len]Route {
    // Los nombres de entidades y el tamaño del array se conocen en compilación;
    // no hace falta registrar rutas al arrancar ni usar reflexión en runtime.
    const names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    var result: [names.len]Route = undefined;
    inline for (names, 0..) |name, index| result[index] = .{ .path = "/api/" ++ name };
    return result;
}

/// `Api` es una fábrica de tipos comptime: no crea ahora un objeto API, sino el
/// *tipo* concreto que después guardará configuración y atenderá solicitudes.
/// Es similar a especializar una plantilla de clase C++, salvo que Zig acepta
/// el modelo normalizado, los codecs y los validadores como entradas comptime.
/// Un registro de validadores vacío (`.{}`) genera handlers sin reglas de negocio.
pub fn Api(
    comptime Model: type,
    // Los codecs también son datos en tiempo de compilación: se comprueba que cada campo
    // expuesto tenga conversiones HTTP/JSON/PostgreSQL antes de arrancar el servidor.
    comptime codecs: anytype,
    // Cada entidad registrada incorpora una llamada directa a su validador.
    // Las entidades omitidas no tienen ninguna rama de validación de negocio.
    comptime validators: anytype,
) type {
    // Framework ya comprobó las entidades y resolvió la nulabilidad efectiva.
    // REST consume esos mismos metadatos sin reinterpretar el contrato.
    const model_info = Model.info;
    const checked_validators = defineBusinessValidators(Model, validators);

    domain_codecs.checkModelCodecs(Model, codecs);

    // El resultado es un tipo struct anónimo especializado para estas entidades
    // y codecs. No se generan archivos fuente del controlador: este tipo *es*
    // el controlador generado y se compila como código Zig escrito a mano.
    return struct {
        // Dentro del struct anónimo devuelto no hay un nombre de tipo en el código;
        // `@This()` lo provee para los receptores de métodos y los tipos de retorno.
        const Self = @This();

        // Los metadatos de rutas son una constante comptime y se pueden inspeccionar
        // sin construir `Self`. Contienen una ruta `/api/<entity>` por entidad
        // y los cuatro métodos CRUD permitidos.
        pub const routes = routeList(model_info);

        // A diferencia del schema, la configuración es estado de runtime: el mismo
        // tipo API generado puede instanciarse con distintos límites de cuerpo de solicitud.
        config: Config,

        // Un constructor convencional explicita la inicialización y permite agregar
        // campos de runtime en el futuro sin cambiar el código que lo llama.
        pub fn init(config: Config) Self {
            // Zig infiere `Self` del tipo de retorno declarado: acá solo hace falta
            // escribir el campo que se inicializa.
            return .{ .config = config };
        }

        // `handle` es el punto de entrada independiente del transporte. `std_http`
        // convierte una solicitud de socket en `Request`; los tests pueden llamar directamente.
        pub fn handle(
            // Se usa un puntero porque la API generada contiene configuración de runtime
            // y podría incorporar estado mutable, aunque ahora sea de solo lectura.
            self: *Self,
            // Quien llama debe liberar el `Response.body` reservado y devuelto acá.
            allocator: std.mem.Allocator,
            // El repositorio tiene tipado estructural: una implementación falsa y la de
            // PostgreSQL funcionan sin herencia, objeto de interfaz ni dependencia
            // directa de este módulo respecto de libpq.
            repository: anytype,
            // El método, destino, headers y cuerpo ya son independientes del transporte.
            request: Request,
        ) !Response {
            // El parseo crea muchos strings, arrays y nodos JSON de corta duración.
            // Una arena por solicitud permite liberarlos en una sola acción determinista.
            var scratch = std.heap.ArenaAllocator.init(allocator);
            // Esto corre en cada salida, incluidos errores y respuestas HTTP anticipadas,
            // y libera juntas todas las reservas temporales de la solicitud.
            defer scratch.deinit();
            // Los helpers y repositorios reciben este allocator para valores temporales;
            // solo la respuesta final usa el allocator de quien llama.
            const scratch_allocator = scratch.allocator();

            // Rechaza cuerpos demasiado grandes antes de parsear JSON o acceder al
            // repositorio. El adaptador de sockets también impone el límite al leer;
            // esta comprobación protege por igual las llamadas directas a `handle`.
            if (request.body.len > self.config.max_body_bytes)
                return responses.requestValidationResponse(allocator, error.BodyTooLarge);

            // Busca una sola vez el primer separador de query. `null` indica que
            // el destino de esta solicitud contiene únicamente una ruta.
            const question = std.mem.indexOfScalar(u8, request.target, '?');
            // La ruta excluye `?` y todo lo que sigue. Los slices toman prestado
            // el destino inmutable de la solicitud, sin reservar memoria ni copiarlo.
            const path = if (question) |index| request.target[0..index] else request.target;
            // Del mismo modo, la query son los bytes posteriores a `?` o un slice vacío.
            const query = if (question) |index| request.target[index + 1 ..] else "";

            // Este controlador generado gestiona solo el espacio `/api/`. Otro
            // adaptador o router puede atender verificaciones de estado o archivos estáticos.
            if (!std.mem.startsWith(u8, path, "/api/"))
                return responses.errorResponse(allocator, 404, "not_found", "Route not found");

            // Se quitan cinco bytes porque `"/api/".len == 5`; el resto debe ser
            // exactamente un nombre de entidad, como `"docentes"`.
            const entity_path = path[5..];
            // Los nombres vacíos y los segmentos anidados no son rutas de colecciones
            // de entidades; esta fase no incluye rutas con forma `/api/entity/id`.
            if (entity_path.len == 0 or std.mem.indexOfScalar(u8, entity_path, '/') != null)
                return responses.errorResponse(allocator, 404, "not_found", "Route not found");

            // Este bucle comptime genera una rama normal de comparación de strings por
            // entidad conocida. Runtime elige una rama, pero el handler seleccionado
            // está especializado con un nombre de entidad y un schema comptime.
            inline for (@typeInfo(@TypeOf(model_info)).@"struct".field_names) |entity_name| {
                // Los nombres de entidades provienen solo de la SSOT validada: texto
                // arbitrario de la URL nunca puede convertirse después en identificador
                // PostgreSQL.
                if (std.mem.eql(u8, entity_path, entity_name))
                    return handleEntity(self, allocator, scratch_allocator, repository, request, query, entity_name);
            }

            // La ruta tenía la forma correcta, pero no nombraba ninguna entidad de la SSOT.
            return responses.errorResponse(allocator, 404, "not_found", "Entity not found");
        }

        // Este helper contiene la validación y el comportamiento CRUD de la entidad.
        // Sigue siendo genérico respecto del repositorio, pero se especializa por entidad.
        fn handleEntity(
            self: *Self,
            // Los bytes de la respuesta JSON final deben sobrevivir a esta función:
            // usan el allocator de respuesta de quien llama.
            response_allocator: std.mem.Allocator,
            // Los filtros decodificados, JSON parseado y filas de base son locales a la
            // solicitud.
            scratch_allocator: std.mem.Allocator,
            repository: anytype,
            request: Request,
            query: []const u8,
            // Este parámetro es clave: permite que `@field` e `inline for` usen el
            // schema exacto de la entidad al compilar cada rama generada.
            comptime entity_name: []const u8,
        ) !Response {
            // `handle` necesitaba `self` para acceder a la configuración; este helper no
            // necesita estado de instancia por ahora. Descartarlo explícitamente satisface
            // la comprobación Zig de parámetros sin uso y documenta esa decisión.
            _ = self;

            // Como `entity_name` se conoce en comptime, esto selecciona la definición
            // concreta de entidad sin buscar en un mapa de runtime.
            const entity = @field(model_info, entity_name);

            const filters = requests.decodeFilters(scratch_allocator, entity, codecs, query) catch |err|
                return responses.requestValidationResponse(response_allocator, err);

            // Los cuatro métodos CRUD comparten la preparación de rutas y filtros;
            // se separan recién cuando la solicitud está ligada a un schema de entidad válido.
            switch (request.method) {
                .GET => {
                    // GET admite cero filtros (`SELECT *`) o cualquier cantidad de
                    // filtros de igualdad que el repositorio combina con `AND`.
                    var result = repository.select(scratch_allocator, entity_name, filters) catch |err|
                        // Los errores del repositorio se traducen de forma centralizada: los
                        // conflictos de restricciones, la indisponibilidad y los fallos
                        // internos
                        // no exponen diagnósticos de PostgreSQL en la respuesta HTTP.
                        return responses.repositoryErrorResponse(response_allocator, err);

                    // Los resultados contienen columnas y filas propias y deben liberarlas
                    // en cada salida de la serialización. Con libpq, esto libera su arena.
                    defer result.deinit();

                    // GET genera un array JSON y devuelve 200. El `false` final indica
                    // que se esperan cero o más filas, no una fila obligatoria.
                    return responses.fromResult(response_allocator, scratch_allocator, entity, codecs, result, 200, false);
                },

                .POST => {
                    // POST crea una entidad y no acepta filtros de selección.
                    // Rechazarlos evita una semántica de inserción ambigua.
                    if (query.len != 0) return responses.requestValidationResponse(response_allocator, error.UnexpectedQuery);

                    var parsed = requests.parseBody(scratch_allocator, entity, request) catch |err|
                        return responses.requestValidationResponse(response_allocator, err);
                    defer parsed.deinit();

                    // Recorre campos en orden SSOT, exige PK y campos efectivamente NOT NULL,
                    // completa los nullable omitidos con SQL NULL y pasa cada valor
                    // no-null por el codec JSON de su dominio.
                    const values = requests.buildInsertValues(scratch_allocator, entity, codecs, parsed.value.object) catch |err|
                        return responses.requestValidationResponse(response_allocator, err);

                    // Los validadores de negocio reciben la fila completa normalizada,
                    // incluidos los SQL NULL que completan propiedades nullable omitidas.
                    if (comptime @hasField(@TypeOf(checked_validators), entity_name)) {
                        const validator = @field(checked_validators, entity_name);
                        const row = validation.decodeRow(Model, entity_name, codecs, scratch_allocator, values) catch |err|
                            return responses.businessValidationErrorResponse(response_allocator, err);
                        if (validator.validate(row)) |details|
                            return responses.businessViolationResponse(response_allocator, details);
                    }

                    // El repositorio emite INSERT ... RETURNING * parametrizado.
                    var result = repository.insert(scratch_allocator, entity_name, values) catch |err|
                        return responses.repositoryErrorResponse(response_allocator, err);
                    defer result.deinit();

                    // Un POST exitoso devuelve 201 y exactamente una fila;
                    // `single = true` convierte cualquier otra cantidad en un error de contrato.
                    return responses.fromResult(response_allocator, scratch_allocator, entity, codecs, result, 201, true);
                },

                .PUT => {
                    // Esta API no admite actualizaciones masivas sin restricciones:
                    // al menos un filtro de igualdad debe identificar las filas destino.
                    if (filters.len == 0) return responses.requestValidationResponse(response_allocator, error.FilterRequired);

                    var parsed = requests.parseBody(scratch_allocator, entity, request) catch |err|
                        return responses.requestValidationResponse(response_allocator, err);
                    defer parsed.deinit();

                    // Este helper exige un cuerpo parcial no vacío, rechaza cambios de PK,
                    // comprueba nulabilidad y aplica codecs JSON. Emite los valores
                    // en orden de campos de la entidad para generar SQL estable.
                    const values = requests.buildUpdateValues(scratch_allocator, entity, codecs, parsed.value.object) catch |err|
                        return responses.requestValidationResponse(response_allocator, err);

                    // Una actualización parcial no se puede validar por sí sola: la regla
                    // puede depender de una columna que no cambia. Solo las entidades con
                    // un validador registrado ejecutan este SELECT preparatorio.
                    if (comptime @hasField(@TypeOf(checked_validators), entity_name)) {
                        var current = repository.select(scratch_allocator, entity_name, filters) catch |err|
                            return responses.repositoryErrorResponse(response_allocator, err);
                        defer current.deinit();

                        const validator = @field(checked_validators, entity_name);
                        const violation = validation.validateUpdatedRows(Model, entity_name, codecs, scratch_allocator, current, values, validator) catch |err|
                            return responses.businessValidationErrorResponse(response_allocator, err);
                        if (violation) |details|
                            return responses.businessViolationResponse(response_allocator, details);
                    }

                    // El repositorio produce UPDATE ... WHERE ... RETURNING * parametrizado
                    // y numera los valores de actualización antes que los de filtros.
                    var result = repository.update(scratch_allocator, entity_name, values, filters) catch |err|
                        return responses.repositoryErrorResponse(response_allocator, err);
                    defer result.deinit();

                    // PUT devuelve un array porque el filtro puede coincidir con cero,
                    // una o varias filas. Cero coincidencias produce `200 []`, no 404.
                    return responses.fromResult(response_allocator, scratch_allocator, entity, codecs, result, 200, false);
                },

                .DELETE => {
                    // Como en PUT, se rechaza la eliminación sin restricciones.
                    if (filters.len == 0) return responses.requestValidationResponse(response_allocator, error.FilterRequired);

                    // DELETE no tiene cuerpo JSON; los filtros ya validados bastan
                    // para DELETE ... RETURNING * parametrizado.
                    var result = repository.delete(scratch_allocator, entity_name, filters) catch |err|
                        return responses.repositoryErrorResponse(response_allocator, err);
                    defer result.deinit();

                    // Devuelve todas las filas eliminadas como array. Sin coincidencias,
                    // devuelve `200 []` exitoso porque la solicitud sigue siendo válida.
                    return responses.fromResult(response_allocator, scratch_allocator, entity, codecs, result, 200, false);
                },

                // `.other` representa los métodos std.http ajenos al contrato CRUD de esta
                // fase, incluidos PATCH y HEAD. La ruta de entidad existe: corresponde
                // 405 en lugar de 404.
                .other => return responses.errorResponse(response_allocator, 405, "method_not_allowed", "Allowed methods: GET, POST, PUT, DELETE"),
            }
        }
    };
}
