#!/usr/bin/env bash
# Post-start setup script for UVL-EMR Mugamba
# Run this after 'bash start.sh' completes

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="ozone-uvl-mugamba"

echo "=== UVL-EMR Post-Start Setup ==="

# Fix OpenMRS data directory permissions
echo "=== Fixing OpenMRS data permissions ==="
OPENMRS_IMAGE=$(docker inspect ozone-uvl-mugamba-openmrs-1 --format "{{.Config.Image}}" 2>/dev/null)
if [ -n "$OPENMRS_IMAGE" ]; then
  docker run --rm     -v ozone-uvl-mugamba_openmrs-data:/openmrs/data     --entrypoint sh     $OPENMRS_IMAGE     -c "chmod -R 777 /openmrs/data/modules/ 2>/dev/null; echo Done" || true
  echo "→ Permissions fixed"
fi

# Helper: run MySQL command
mysql_exec() {
  local sql="$1"
  local env_file="$SCRIPT_DIR/../target/ozone-uvl-mugamba-1.0.0-SNAPSHOT/run/docker/concatenated.env"
  local pw=$(grep "MYSQL_ROOT_PASSWORD" "$env_file" | head -1 | cut -d'=' -f2)
  docker exec ${PROJECT_NAME}-mysql-1 mysql -u root -p"$pw" openmrs -e "$sql" 2>/dev/null
}

# 1. Wait for OpenMRS
echo "→ Waiting for OpenMRS..."
until curl -sf -u admin:Admin123 http://localhost/openmrs/ws/rest/v1/ > /dev/null 2>&1; do
  sleep 10
done
echo "→ OpenMRS ready"

# 2. Wait for Orthanc
echo "→ Waiting for Orthanc..."
until curl -sf http://localhost:8889/system > /dev/null 2>&1; do
  sleep 5
done
echo "→ Orthanc ready"

# 3. nginx CORS patch for Orthanc
echo "=== Patching nginx CORS ==="
docker exec ${PROJECT_NAME}-proxy-1 sh -c "
  if ! grep -q 'orthanc-cors' /etc/nginx/conf.d/default.conf; then
    sed -i 's|location = / {|location /orthanc-cors/ {\n        if (\$request_method = OPTIONS) {\n            add_header Access-Control-Allow-Origin \"*\" always;\n            add_header Access-Control-Allow-Methods \"GET, POST, PUT, DELETE, OPTIONS\" always;\n            add_header Access-Control-Allow-Headers \"Authorization, Content-Type, Accept, token\" always;\n            add_header Content-Length 0;\n            return 204;\n        }\n        add_header Access-Control-Allow-Origin \"*\" always;\n        add_header Access-Control-Allow-Headers \"Authorization, Content-Type, Accept, token\" always;\n        proxy_pass http://orthanc:8042/;\n        proxy_set_header Host \$host;\n        proxy_set_header token \$http_token;\n        proxy_set_header Authorization \$http_authorization;\n    }\n\n    location = / {|' /etc/nginx/conf.d/default.conf
    echo '→ CORS patch applied'
  else
    echo '→ CORS patch already present'
  fi
" && docker exec ${PROJECT_NAME}-proxy-1 nginx -s reload
echo "→ nginx reloaded"

# 4. Keycloak setup
echo "=== Configuring Keycloak ==="
docker exec ${PROJECT_NAME}-keycloak-1 \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password password

docker exec ${PROJECT_NAME}-keycloak-1 \
  /opt/keycloak/bin/kcadm.sh add-roles -r ozone \
  --uusername service-account-orthanc-service --rolename admin 2>/dev/null || true

docker exec ${PROJECT_NAME}-keycloak-1 \
  /opt/keycloak/bin/kcadm.sh set-password \
  -r ozone --username jdoe --new-password Test1234x 2>/dev/null || true
echo "→ Keycloak configured"

# 5. Fix duplicate provider
echo "=== Fixing providers ==="
mysql_exec "UPDATE provider SET retired=1, retire_reason='Duplicate', retired_by=1, date_retired=NOW() 
  WHERE uuid='f9badd80-ab76-11e2-9e96-0800200c9a66' AND retired=0;"
echo "→ Providers fixed"

# 6. Update Orthanc imaging configuration
echo "=== Updating imaging configuration ==="
mysql_exec "UPDATE imaging_OrthancConfiguration 
  SET orthancUsername='orthanc-service', orthancPassword='zfQBuufpLoIQ4H6adktXAVvOin1nrR6R'
  WHERE id=1;"
echo "→ Imaging configuration updated"

# 7. Deploy imaging ESM frontend
echo "=== Deploying imaging ESM ==="
FRONTEND_DIR="$SCRIPT_DIR/../target/ozone-uvl-mugamba-1.0.0-SNAPSHOT/distro/binaries/openmrs/frontend"
ESM_DIR="$FRONTEND_DIR/zhaosadre-esm-patient-imaging-app-1.0.6"
ESM_SRC="/Users/v.ameil/Developer/openmrs-esm-patient-imaging-app/dist"

mkdir -p "$ESM_DIR"
cp -r "$ESM_SRC/"* "$ESM_DIR/"

python3 << PYEOF
import json, os
frontend_dir = "$FRONTEND_DIR"
importmap_path = f"{frontend_dir}/importmap.json"
with open(importmap_path) as f:
    d = json.load(f)
d['imports']['@openmrs/esm-patient-imaging-app'] = './zhaosadre-esm-patient-imaging-app-1.0.6/openmrs-esm-patient-imaging-app.js'
with open(importmap_path, 'w') as f:
    json.dump(d, f, indent=2)
routes_path = f"{frontend_dir}/routes.registry.json"
routes_src = f"{frontend_dir}/zhaosadre-esm-patient-imaging-app-1.0.6/routes.json"
if os.path.exists(routes_path) and os.path.exists(routes_src):
    with open(routes_path) as f:
        r = json.load(f)
    with open(routes_src) as f:
        routes = json.load(f)
    r['@openmrs/esm-patient-imaging-app'] = routes
    with open(routes_path, 'w') as f:
        json.dump(r, f, indent=2)
print("→ Imaging ESM deployed")
PYEOF

# 8. Deploy attachments ESM patch
echo "=== Deploying attachments ESM patch ==="
cp -r /Users/v.ameil/Developer/openmrs-esm-patient-chart-upstream/packages/esm-patient-attachments-app/dist/* \
   /Users/v.ameil/Developer/UVL-EMR/openmrs-esm-patient-chart/packages/esm-patient-attachments-app/dist/ 2>/dev/null || true

echo ""
echo "=== Post-start setup complete! ==="
echo "→ OpenMRS O3: http://localhost/openmrs/spa"
echo "→ Orthanc:    http://localhost:8889"
echo "→ Odoo:       http://localhost:8069"
