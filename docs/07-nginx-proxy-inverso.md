# 07 — Nginx del host + exposición solo del frontend

Escenario: en el servidor hay un **Nginx instalado en el host** (fuera de Docker) que
actúa como proxy inverso. La estrategia elegida: **exponer únicamente el subdominio del
frontend**. El backend **no se expone** — vive solo en la red interna de Docker y el
contenedor frontend hace de proxy de `/api` hacia él.

## Cómo encaja todo

```
                            ┌───────────────────────────────────────────┐
                            │  SERVIDOR                                  │
Internet ──443──► Nginx ────┼──► 127.0.0.1:15001 ─► contenedor FRONTEND  │
        app.tudominio.com   │        (Nginx + Angular SPA)               │
                            │              │  /api/  (red interna Docker)│
                            │              ▼                             │
                            │        contenedor BACKEND (.NET)  :8080    │  ← sin puerto publicado
                            │              │                             │
                            │              ▼                             │
                            │        contenedor MySQL                    │
                            └───────────────────────────────────────────┘
```

- **Solo el frontend** se publica (en `127.0.0.1:15001`, detrás del Nginx del host).
- **El backend NO tiene puerto publicado.** Solo es alcanzable como `backend:8080` dentro
  de la red Docker `internal`.
- El navegador llama a `https://app.tudominio.com/api/...` (mismo origen del frontend).
  El Nginx del contenedor frontend reenvía ese `/api/` al backend por la red interna.

### ¿Por qué el SPA no usa la red Docker directamente?

El Angular se ejecuta en el **navegador del usuario**, que está fuera del servidor: no
tiene acceso a la red interna de Docker. Por eso el truco es que el **Nginx del contenedor
frontend** (que sí está en la red Docker) haga el proxy de `/api` → `backend:8080`. Así el
navegador solo necesita hablar con un origen (el frontend) y el backend queda oculto.

## Lo que ya quedó configurado en el repo

| Archivo | Cambio |
|---------|--------|
| `frontend/nginx.conf` | bloque `location /api/` que hace proxy a `backend:8080` por la red Docker (con `resolver 127.0.0.11` para soportar redeploys) |
| `frontend/src/environments/environment.prod.ts` | `apiBaseUrl: '/api'` (ruta relativa, mismo origen) |
| `docker-compose.deploy.yml` | el servicio `backend` **ya no publica puerto**; solo red `internal` |
| `.env` del servidor | solo `FRONTEND_PORT` (el backend no necesita puerto) |

> El backend enruta todo bajo `/api/...` (todos los controllers usan `[Route("api/...")]`),
> por eso el proxy conserva el prefijo `/api/` sin reescribir.

## Config del Nginx del host (solo frontend)

Como el `/api` lo resuelve el contenedor, el Nginx del host **solo** necesita un bloque:
servir el subdominio del frontend.

### QA — `/etc/nginx/sites-available/consultorapro-qa.conf`

```nginx
server {
    listen 80;
    server_name app.qa.tudominio.com;

    location / {
        proxy_pass http://127.0.0.1:15001;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Activar:

```bash
sudo ln -s /etc/nginx/sites-available/consultorapro-qa.conf /etc/nginx/sites-enabled/
sudo nginx -t          # valida la sintaxis
sudo systemctl reload nginx
```

Para **producción**, duplica el archivo con `server_name app.tudominio.com;` y el puerto de
producción (p. ej. `16001` si compartes servidor con QA — ver [06](06-preparacion-servidor.md)).

## Seguridad de puertos / firewall

- Contenedor frontend atado a `127.0.0.1` (`BIND_HOST=127.0.0.1` en `.env`): no accesible
  desde fuera salvo por el Nginx del host.
- Backend **sin puerto** → imposible alcanzarlo desde fuera del host.
- Firewall: solo abre 22/80/443.

```bash
sudo ufw allow 22/tcp        # SSH
sudo ufw allow 80/tcp        # HTTP (redirige a HTTPS)
sudo ufw allow 443/tcp       # HTTPS
sudo ufw enable
```

## HTTPS con Let's Encrypt (certbot)

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d app.qa.tudominio.com
# (repite con -d app.tudominio.com para producción)
```

Certbot edita tu `server {}` para añadir `listen 443 ssl`, los certificados y la
redirección 80→443. Se renueva solo (timer que ya instala).

## Nota para el backend .NET detrás del proxy

El TLS lo termina el Nginx del host y el tráfico interno es HTTP. Para que la app respete
el esquema/IP real del cliente, conviene activar los **Forwarded Headers** en el .NET:

```csharp
// Program.cs, al inicio del pipeline
app.UseForwardedHeaders(new ForwardedHeadersOptions
{
    ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto
});
```

Tanto el Nginx del contenedor frontend como el del host ya envían `X-Forwarded-For` y
`X-Forwarded-Proto`. Esto es un ajuste en el **código del backend**, aplícalo cuando toque.

## Si en el futuro quieres exponer la API aparte (opcional)

El esquema actual oculta el backend por completo, que es lo recomendable. Si algún día
necesitas que clientes externos (otra app, móvil) consuman la API directamente, podrías
publicar un subdominio `api.tudominio.com`. Para ello tendrías que: volver a publicar el
puerto del backend (atado a `127.0.0.1`) en `docker-compose.deploy.yml` y añadir un
`server {}` en el Nginx del host que haga proxy a ese puerto. No es necesario hoy.

## Checklist

- [ ] `BIND_HOST=127.0.0.1` y sin `BACKEND_PORT` en el `.env` del servidor.
- [ ] Firewall: solo 22/80/443 abiertos.
- [ ] Sitio Nginx del host (solo frontend) creado, `nginx -t` OK, `reload`.
- [ ] DNS del subdominio del frontend apuntando al servidor.
- [ ] HTTPS emitido con certbot.
- [ ] Probar: `https://app.qa.tudominio.com` carga el SPA y `…/api/...` responde.
- [ ] (Backend) Forwarded Headers activados cuando se modifique el código.
