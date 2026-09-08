"""
Deja lista la compañía sobre la que corre la demo.

Se corre DESPUÉS de `make modules` y ANTES de `make seed`:

    make company

Por qué hace falta
------------------
Con demo data, Odoo 19 no deja una sola compañía. El demo de `account` renombra
la principal, le aplica el plan genérico (`generic_coa`, en USD) y además crea
una compañía por cada localización instalada. El resultado típico es:

    My Company (San Francisco) | USD | generic_coa | 1 almacén
    HN Company                 | HNL | hn         | 0 almacenes
    My Company (Chicago)       | USD | -          | 1 almacén

O sea: la compañía con la moneda correcta existe, pero está vacía —sin almacén
no hay `stock_quant`, y sin `stock_quant` no hay inventario que mostrar—; y la
compañía que sí tiene almacén está en la moneda equivocada. Instalar la
localización antes que `account` no lo evita: se probó.

Este script cierra esa brecha: toma la compañía de la moneda de la demo y le
crea el almacén que le falta, para que el seed pueda trabajar ahí.

Es idempotente: si el almacén ya existe, no hace nada.
"""

DEMO_CURRENCY = "HNL"


def pick_company():
    """La compañía de la moneda de la demo. Si no hay, la actual."""
    cs = env["res.company"].search([("currency_id.name", "=", DEMO_CURRENCY)])
    if not cs:
        print(
            f"AVISO: no hay ninguna compañía en {DEMO_CURRENCY}. Se usa "
            f"{env.company.name} ({env.company.currency_id.name}). "
            f"La demo va a mostrar la moneda equivocada."
        )
        return env.company
    # Si la compañía actual ya sirve, no la cambiamos: menos sorpresas.
    return env.company if env.company in cs else cs[0]


company = pick_company()
print(f"Compañía de la demo: {company.name} ({company.currency_id.name})")

# --- Almacén ---------------------------------------------------------------
# Sin almacén no hay ubicaciones internas, y Silver filtra justamente por
# stock_location.usage = 'internal'. Una compañía sin almacén da inventario
# vacío sin ningún error visible, que es la peor forma de fallar.
warehouses = env["stock.warehouse"].search([("company_id", "=", company.id)])
if not warehouses:
    code = (company.name[:5] or "DEMO").upper().replace(" ", "")
    warehouse = env["stock.warehouse"].create(
        {"name": f"Almacén {company.name}", "code": code, "company_id": company.id}
    )
    print(f"  almacén creado: {warehouse.name} ({warehouse.code})")
else:
    print(f"  almacén ya existe: {', '.join(warehouses.mapped('name'))}")

# --- Acceso del admin ------------------------------------------------------
# Para que al entrar por la web se vea esta compañía y no otra.
admin = env.ref("base.user_admin", raise_if_not_found=False) or env.user
if company not in admin.company_ids:
    admin.company_ids = [(4, company.id)]
admin.company_id = company
print(f"  {admin.login}: compañía por defecto = {company.name}")

env.cr.commit()

# --- Resumen ---------------------------------------------------------------
print("\nEstado de las compañías:")
for c in env["res.company"].search([]):
    n = env["stock.warehouse"].search_count([("company_id", "=", c.id)])
    flag = "  <- la de la demo" if c == company else ""
    print(f"  {c.name:<30} {c.currency_id.name:<5} {n} almacén(es){flag}")
