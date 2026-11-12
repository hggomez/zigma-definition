--liquibase formatted sql
--changeset zigma:000001_baseline
--comment: initial schema generated from the Zigma desired state

CREATE TABLE "productos" (
    "id" BIGINT NOT NULL,
    "nombre" TEXT NOT NULL,
    "descripcion" TEXT NOT NULL,
    CONSTRAINT "pk_productos" PRIMARY KEY ("id")
);

CREATE TABLE "productos_precios" (
    "id" BIGINT NOT NULL,
    "id_producto" BIGINT NOT NULL,
    "vigencia_desde" TIMESTAMPTZ NOT NULL,
    "precio" BIGINT NOT NULL,
    CONSTRAINT "pk_productos_precios" PRIMARY KEY ("id"),
    CONSTRAINT "uk_productos_precios_producto_vigencia" UNIQUE ("id_producto", "vigencia_desde"),
    CONSTRAINT "uk_productos_precios_producto_id" UNIQUE ("id_producto", "id"),
    CONSTRAINT "fk_productos_precios_producto" FOREIGN KEY ("id_producto") REFERENCES "productos" ("id")
);

CREATE TABLE "clientes" (
    "id" BIGINT NOT NULL,
    "nombre" TEXT NOT NULL,
    CONSTRAINT "pk_clientes" PRIMARY KEY ("id")
);

CREATE TABLE "carritos" (
    "id" BIGINT NOT NULL,
    "fecha_inicio" TIMESTAMPTZ NOT NULL,
    "estado" TEXT NOT NULL,
    "id_cliente" BIGINT,
    CONSTRAINT "pk_carritos" PRIMARY KEY ("id"),
    CONSTRAINT "fk_carritos_cliente" FOREIGN KEY ("id_cliente") REFERENCES "clientes" ("id")
);

CREATE TABLE "descuentos_cantidad" (
    "id" BIGINT NOT NULL,
    "id_producto" BIGINT NOT NULL,
    "vigencia_desde" TIMESTAMPTZ NOT NULL,
    "cantidad_llevar" BIGINT NOT NULL,
    "descuento_porcentaje" BIGINT NOT NULL,
    "activo" BOOLEAN NOT NULL,
    CONSTRAINT "pk_descuentos_cantidad" PRIMARY KEY ("id"),
    CONSTRAINT "uk_descuentos_cantidad_producto_vigencia" UNIQUE ("id_producto", "vigencia_desde"),
    CONSTRAINT "uk_descuentos_cantidad_producto_id" UNIQUE ("id_producto", "id"),
    CONSTRAINT "fk_descuentos_cantidad_producto" FOREIGN KEY ("id_producto") REFERENCES "productos" ("id")
);

CREATE TABLE "tickets" (
    "id" BIGINT NOT NULL,
    "id_carrito" BIGINT NOT NULL,
    "fecha_emision" TIMESTAMPTZ NOT NULL,
    "total" BIGINT NOT NULL,
    "id_cliente" BIGINT,
    CONSTRAINT "pk_tickets" PRIMARY KEY ("id"),
    CONSTRAINT "uk_tickets_carrito" UNIQUE ("id_carrito"),
    CONSTRAINT "fk_tickets_carrito" FOREIGN KEY ("id_carrito") REFERENCES "carritos" ("id"),
    CONSTRAINT "fk_tickets_cliente" FOREIGN KEY ("id_cliente") REFERENCES "clientes" ("id")
);

CREATE TABLE "tickets_productos" (
    "id_ticket" BIGINT NOT NULL,
    "id_producto" BIGINT NOT NULL,
    "cantidad" BIGINT NOT NULL,
    "precio_unitario" BIGINT NOT NULL,
    "importe_descuento" BIGINT NOT NULL,
    CONSTRAINT "pk_tickets_productos" PRIMARY KEY ("id_ticket", "id_producto"),
    CONSTRAINT "fk_tickets_productos_ticket" FOREIGN KEY ("id_ticket") REFERENCES "tickets" ("id"),
    CONSTRAINT "fk_tickets_productos_producto" FOREIGN KEY ("id_producto") REFERENCES "productos" ("id")
);

CREATE TABLE "productos_carritos" (
    "id_carrito" BIGINT NOT NULL,
    "id_producto" BIGINT NOT NULL,
    "cantidad" BIGINT NOT NULL,
    "id_precio" BIGINT NOT NULL,
    "id_descuento" BIGINT,
    CONSTRAINT "pk_productos_carritos" PRIMARY KEY ("id_carrito", "id_producto"),
    CONSTRAINT "fk_productos_carritos_carrito" FOREIGN KEY ("id_carrito") REFERENCES "carritos" ("id"),
    CONSTRAINT "fk_productos_carritos_producto" FOREIGN KEY ("id_producto") REFERENCES "productos" ("id"),
    CONSTRAINT "fk_productos_carritos_precio" FOREIGN KEY ("id_producto", "id_precio") REFERENCES "productos_precios" ("id_producto", "id"),
    CONSTRAINT "fk_productos_carritos_descuento" FOREIGN KEY ("id_producto", "id_descuento") REFERENCES "descuentos_cantidad" ("id_producto", "id")
);
