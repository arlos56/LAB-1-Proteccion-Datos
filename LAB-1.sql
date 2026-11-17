CREATE ROLE app_ventas LOGIN;
CREATE ROLE soporte_ana LOGIN;
\password app_ventas   
\password soporte_ana  

-- Asignar privilegios
GRANT SELECT, UPDATE ON clientes TO app_ventas;
GRANT SELECT ON clientes TO soporte_ana;

ALTER SYSTEM SET logging_collector = on;

-- 1. Crear esquema y vista para leer la bitácora con SQL
CREATE SCHEMA dba;
REVOKE ALL ON SCHEMA dba FROM PUBLIC;

CREATE VIEW dba.bitacora AS
SELECT t.n AS num, t.linea
FROM regexp_split_to_table(pg_read_file(pg_current_logfile()), E'\n')
WITH ORDINALITY AS t(linea, n)
WHERE t.linea <> '';

-- 2. Configurar qué eventos se auditan
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_disconnections = on;
ALTER SYSTEM SET log_line_prefix = '%m [%p] user=%u db=%d app=%a client=%h ';
ALTER SYSTEM SET log_statement = 'mod'; -- Registra modificaciones (INSERT, UPDATE, DELETE)

-- Recargar configuración sin cortar sesiones
SELECT pg_reload_conf();

-- 1. Crear esquema y tabla de auditoría
CREATE SCHEMA auditoria;
REVOKE ALL ON SCHEMA auditoria FROM PUBLIC;

CREATE TABLE auditoria.cambios_clientes (
    id_evento BIGSERIAL PRIMARY KEY,
    momento TIMESTAMPTZ NOT NULL DEFAULT now(),
    usuario_sesion TEXT NOT NULL DEFAULT session_user,
    usuario_efectivo TEXT NOT NULL DEFAULT current_user,
    aplicacion TEXT DEFAULT current_setting('application_name'),
    ip_cliente INET DEFAULT inet_client_addr(),
    operacion TEXT NOT NULL,
    id_cliente BIGINT,
    valores_antes JSONB,
    valores_despues JSONB
);

-- 2. Crear función del disparador (COMPLETA)
CREATE OR REPLACE FUNCTION auditoria.registrar_cambio_cliente()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO auditoria.cambios_clientes (operacion, id_cliente, valores_despues)
        VALUES (TG_OP, NEW.id, to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO auditoria.cambios_clientes (operacion, id_cliente, valores_antes, valores_despues)
        VALUES (TG_OP, NEW.id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO auditoria.cambios_clientes (operacion, id_cliente, valores_antes)
        VALUES (TG_OP, OLD.id, to_jsonb(OLD));
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION auditoria.registrar_cambio_cliente() FROM PUBLIC;

-- 3. Vincular el disparador a la tabla
CREATE TRIGGER trg_auditoria_clientes
AFTER INSERT OR UPDATE OR DELETE ON clientes
FOR EACH ROW EXECUTE FUNCTION auditoria.registrar_cambio_cliente();