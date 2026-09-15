//! Diagnóstico esperado: `no field named 'docente'`.
//! 'docente' es un campo de cursos, pero no pertenece a la PK;
//! por eso el record extraído no lo contiene.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    const cursos_pk_fields = zigma.extractPk(aida.cursos);
    _ = cursos_pk_fields.docente;
}
