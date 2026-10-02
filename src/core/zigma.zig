//! zigma-definition: la parte descriptiva del framework SSOTIGAD en Zig.
//! Las definiciones son valores comptime. Los tipos estáticos (el tipo de instancia
//! de un record y el lado Info de una Def) se derivan de esos valores mediante
//! funciones comptime, de modo que los campos se escriben una sola vez.
//!
//! Convención de nombres heredada del módulo TypeScript system-design:
//! una Def es lo que escribe la persona, solo lo semánticamente necesario;
//! el resto tiene defaults. Una Info es la Def completada con todos los defaults
//! explícitos. La Info de entidades contiene valores simples serializables: los comportamientos
//! especiales se referencian por nombre y se resuelven contra implementaciones registradas
//! aparte.
//! La entrada pública conserva todos los nombres de la API. La implementación se
//! divide en records, entidades y modelo; sus helpers internos no se reexportan.

const records = @import("records.zig");
const entities = @import("entities.zig");
const model = @import("model.zig");

// Tipos de dominio, campos, records y composición de definiciones.
pub const TypeDef = records.TypeDef;
pub const common_type_defs = records.common_type_defs;
pub const defineTypes = records.defineTypes;
pub const FieldInfo = records.FieldInfo;
pub const record = records.record;
pub const RecordInstanceType = records.RecordInstanceType;
pub const RecordInfoOf = records.RecordInfoOf;
pub const completeRecord = records.completeRecord;
pub const Merged = records.Merged;
pub const merge = records.merge;

// Entidades: claves, relaciones y metadatos de reglas.
pub const defineEntity = entities.defineEntity;
pub const extractPk = entities.extractPk;
pub const mergePk = entities.mergePk;
pub const completeEntity = entities.completeEntity;
pub const defineEntities = entities.defineEntities;
pub const RuleInfo = entities.RuleInfo;

// Modelo compartido por los generadores, construido desde el contrato.
pub const Framework = model.Framework;
