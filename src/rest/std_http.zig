//! Adaptador secuencial pequeño de HTTP/1.1 para `zigma_rest`, con las funciones
//! de red de la biblioteca estándar de Zig. Cada conexión TCP atiende una solicitud y se
//! cierra. Incluye CORS permisivo (`*`) para poder abrir el frontend de ejemplo desde
//! otro origen (p. ej. `:8000` → `:8080`).

const std = @import("std");
const rest = @import("zigma_rest");

pub const Config = struct {
    // Los defaults acotados y de acceso solo local son adecuados para un servidor
    // de referencia. Un adaptador de producción puede conservar Api y agregar concurrencia y
    // TLS.
    address: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    max_header_bytes: usize = 16 * 1024,
    max_body_bytes: usize = 1024 * 1024,
    /// Útil sobre todo para integrar el servidor y probarlo de forma determinista.
    /// `null` hace que atienda solicitudes hasta que se detenga el proceso.
    max_requests: ?usize = null,
};

const cors_origin = std.http.Header{
    .name = "Access-Control-Allow-Origin",
    .value = "*",
};
const cors_methods = std.http.Header{
    .name = "Access-Control-Allow-Methods",
    .value = "GET, POST, PUT, DELETE, OPTIONS",
};
const cors_headers = std.http.Header{
    .name = "Access-Control-Allow-Headers",
    .value = "Content-Type",
};
const json_content_type = std.http.Header{
    .name = "Content-Type",
    .value = "application/json",
};

fn methodFromStd(method: std.http.Method) rest.Method {
    // La política de métodos queda en el núcleo REST: los verbos no soportados
    // se convierten en `.other` y el despacho generado devuelve una respuesta 405 uniforme.
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .DELETE => .DELETE,
        else => .other,
    };
}

fn send(
    request: *std.http.Server.Request,
    status: u16,
    body: []const u8,
) !void {
    // El núcleo REST usa estados numéricos; se convierten en la interfaz con std.http.
    // keep_alive=false hace que cada conexión aceptada corresponda a una solicitud.
    try request.respond(body, .{
        .status = @fromBackingInt(@intCast(status)),
        .keep_alive = false,
        .extra_headers = &.{ json_content_type, cors_origin },
    });
}

fn sendOptions(request: *std.http.Server.Request) !void {
    try request.respond("", .{
        .status = .no_content,
        .keep_alive = false,
        .extra_headers = &.{ cors_origin, cors_methods, cors_headers },
    });
}

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    api: anytype,
    repository: anytype,
    config: Config,
) !void {
    // `api` y `repository` tienen tipado estructural y se toman prestados durante
    // la vida de este servidor bloqueante; este adaptador no es responsable de liberarlos.
    const address = try std.Io.net.IpAddress.parse(config.address, config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var served: usize = 0;
    while (config.max_requests == null or served < config.max_requests.?) {
        // Bucle de referencia secuencial: termina una conexión antes de aceptar
        // la siguiente. Acá se prioriza la corrección sobre el volumen de solicitudes.
        const stream = try listener.accept(io);
        defer stream.close(io);

        // Headers, cuerpo, slices copiados y respuesta final comparten una arena por
        // solicitud. Cada vía, incluidos los errores, tiene una única limpieza.
        var request_arena = std.heap.ArenaAllocator.init(allocator);
        defer request_arena.deinit();
        const request_allocator = request_arena.allocator();
        // std.http recibe buffers de quien llama, lo que también explicita el máximo
        // de memoria para headers en lugar de ocultarlo dentro del servidor.
        const input_buffer = try request_allocator.alloc(u8, config.max_header_bytes);
        const output_buffer = try request_allocator.alloc(u8, 16 * 1024);
        var stream_reader = stream.reader(io, input_buffer);
        var stream_writer = stream.writer(io, output_buffer);
        var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = server.receiveHead() catch {
            served += 1;
            continue;
        };

        if (request.head.method == .OPTIONS) {
            try sendOptions(&request);
            served += 1;
            continue;
        }

        const method = methodFromStd(request.head.method);
        // Leer el cuerpo puede reutilizar el buffer de entrada HTTP. Copia antes el
        // destino y el tipo de contenido para que Api no observe bytes sobrescritos.
        const target = try request_allocator.dupe(u8, request.head.target);
        const content_type = if (request.head.content_type) |value|
            try request_allocator.dupe(u8, value)
        else
            null;

        if (request.head.content_length) |length| {
            // Rechaza un cuerpo declarado demasiado grande antes de reservar memoria o leerlo.
            if (length > config.max_body_bytes) {
                try send(
                    &request,
                    413,
                    "{\"error\":{\"code\":\"body_too_large\",\"message\":\"Request body exceeds the configured limit\"}}",
                );
                served += 1;
                continue;
            }
        }

        var body_buffer: [8192]u8 = undefined;
        const body_reader = request.readerExpectContinue(&body_buffer) catch {
            served += 1;
            continue;
        };
        // El límite del reader también protege solicitudes fragmentadas o con longitud
        // mal declarada, para las que Content-Length no permite la comprobación anticipada.
        const body = body_reader.allocRemaining(
            request_allocator,
            .limited(config.max_body_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => {
                try send(
                    &request,
                    413,
                    "{\"error\":{\"code\":\"body_too_large\",\"message\":\"Request body exceeds the configured limit\"}}",
                );
                served += 1;
                continue;
            },
            else => return err,
        };

        // Desde acá, la capa de sockets deja de importar: Api recibe el mismo valor
        // Request que entregaría un test unitario u otra biblioteca HTTP.
        const response = api.handle(request_allocator, repository, .{
            .method = method,
            .target = target,
            .content_type = content_type,
            .body = body,
        }) catch {
            // Los errores Zig inesperados se filtran en la última interfaz para
            // no exponer diagnósticos de implementación ni de la base de datos.
            try send(
                &request,
                500,
                "{\"error\":{\"code\":\"internal_error\",\"message\":\"Internal server error\"}}",
            );
            served += 1;
            continue;
        };
        try send(&request, response.status, response.body);
        // Un max_requests finito permite terminar de forma determinista al integrar
        // el servidor o probarlo; null mantiene un servidor normal en ejecución indefinida.
        served += 1;
    }
}
