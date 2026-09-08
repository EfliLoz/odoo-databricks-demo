"""
Fija país (Honduras) y moneda (HNL) en la compañía.

Se corre DESPUÉS de crear la base y ANTES de instalar `account`:

    docker compose -f odoo/docker-compose.yml run --rm -T odoo \
      odoo shell -d demo --no-http < odoo/scripts/localize_hn.py

o, desde la raíz del repo:

    make localize

El orden no es negociable. Odoo instala la localización contable según el país
de la compañía; sin país configurado cae en l10n_generic_coa (US) y te quedás
en dólares. Y la moneda de la compañía NO se puede cambiar una vez que existen
asientos contables: si te equivocás, se recrea la base.

El -T es obligatorio: sin él, compose no conecta el stdin y el script no entra.

Idempotente: correrlo dos veces no hace daño.
"""

hnl = env["res.currency"].with_context(active_test=False).search(
    [("name", "=", "HNL")], limit=1
)
if not hnl:
    raise SystemExit("No existe la moneda HNL en esta base. ¿Instalaste el módulo base?")

hnl.active = True
env.company.country_id = env.ref("base.hn")
env.company.currency_id = hnl
env.cr.commit()

print(
    f"Compañía: {env.company.name} | país: {env.company.country_id.name} "
    f"| moneda: {env.company.currency_id.name}"
)
