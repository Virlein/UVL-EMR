#!/bin/bash
set -e

KEYCLOAK_URL="http://localhost:8084"
MAX_WAIT=180
WAITED=0

echo "=== Waiting for Keycloak to be ready ==="
until curl -sf "$KEYCLOAK_URL/realms/ozone" > /dev/null 2>&1; do
  sleep 5
  WAITED=$((WAITED + 5))
  if [ $WAITED -ge $MAX_WAIT ]; then
    echo "Keycloak not ready after ${MAX_WAIT}s"
    exit 1
  fi
  echo "Waiting... (${WAITED}s)"
done
echo "→ Keycloak ready"

echo ""
echo "=== Getting admin token ==="
ADMIN_TOKEN=$(curl -sf -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=password" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
echo "→ Token obtained"

echo ""
echo "=== Checking orthanc-service client ==="
EXISTS=$(curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/ozone/clients?clientId=orthanc-service" \
  | python3 -c "import sys,json; print('yes' if json.load(sys.stdin) else 'no')")

if [ "$EXISTS" = "yes" ]; then
  echo "→ orthanc-service already exists, skipping"
else
  curl -sf -X POST "$KEYCLOAK_URL/admin/realms/ozone/clients" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "orthanc-service",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "zfQBuufpLoIQ4H6adktXAVvOin1nrR6R",
      "serviceAccountsEnabled": true,
      "publicClient": false,
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "protocol": "openid-connect"
    }'
  echo "→ orthanc-service client created"
fi

echo ""
echo "=== Done! Keycloak is configured ==="

echo ""
echo "=== Creating admin role and assigning to orthanc-service ==="
curl -sf -X POST "http://localhost:8084/admin/realms/ozone/roles" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"admin"}' 2>/dev/null && echo "→ admin role created" || echo "→ admin role already exists"

ADMIN_ROLE_ID=$(curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://localhost:8084/admin/realms/ozone/roles/admin" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

CLIENT_UUID=$(curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://localhost:8084/admin/realms/ozone/clients?clientId=orthanc-service" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

SA_USER_ID=$(curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://localhost:8084/admin/realms/ozone/clients/$CLIENT_UUID/service-account-user" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

curl -sf -X POST \
  "http://localhost:8084/admin/realms/ozone/users/$SA_USER_ID/role-mappings/realm" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "[{\"id\":\"$ADMIN_ROLE_ID\",\"name\":\"admin\"}]" && echo "→ admin role assigned to orthanc-service"

# Create orthanc client (used by orthanc-auth-service)
echo "=== Checking orthanc client ==="
ORTHANC_CLIENT=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/ozone/clients?clientId=orthanc" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
if [ "$ORTHANC_CLIENT" = "0" ]; then
  curl -s -X POST "$KEYCLOAK_URL/admin/realms/ozone/clients" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"clientId":"orthanc","enabled":true,"publicClient":true,"directAccessGrantsEnabled":true,"standardFlowEnabled":true}'
  echo "→ orthanc client created"
else
  echo "→ orthanc client already exists"
fi

# Configure orthanc client with PKCE
echo "=== Configuring orthanc client with PKCE ==="

ORTHANC_CLIENT_ID=$(curl -s "$KEYCLOAK_URL/admin/realms/ozone/clients?clientId=orthanc" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")

if [ -n "$ORTHANC_CLIENT_ID" ]; then
  curl -s -X PUT "$KEYCLOAK_URL/admin/realms/ozone/clients/$ORTHANC_CLIENT_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"publicClient":true,"attributes":{"pkce.code.challenge.method":"S256"},"standardFlowEnabled":true,"directAccessGrantsEnabled":true,"redirectUris":["*"],"webOrigins":["*"]}'
  echo "→ orthanc client configured with PKCE"
fi

# Add admin role to jdoe
echo "=== Adding admin role to jdoe ==="
curl -s -X POST "$KEYCLOAK_URL/admin/realms/ozone/users" \
  -H "Authorization: Bearer $ADMIN_TOKEN" > /dev/null 2>&1
JDOE_ID=$(curl -s "$KEYCLOAK_URL/admin/realms/ozone/users?username=jdoe" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")

ADMIN_ROLE_ID=$(curl -s "$KEYCLOAK_URL/admin/realms/ozone/roles/admin" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))")

if [ -n "$JDOE_ID" ] && [ -n "$ADMIN_ROLE_ID" ]; then
  curl -s -X POST "$KEYCLOAK_URL/admin/realms/ozone/users/$JDOE_ID/role-mappings/realm" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "[{\"id\":\"$ADMIN_ROLE_ID\",\"name\":\"admin\"}]"
  echo "→ admin role assigned to jdoe"
fi

# --- OpenMRS SSO login support (idempotent) ---

# Create a real "admin" Keycloak user matching OpenMRS's native admin
# username, required for SSO login to authenticate as that account at all.
echo ""
echo "=== Ensuring Keycloak 'admin' user exists (for OpenMRS SSO login) ==="
KC_ADMIN_USER_ID=$(curl -s "$KEYCLOAK_URL/admin/realms/ozone/users?username=admin" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")
if [ -z "$KC_ADMIN_USER_ID" ]; then
  curl -s -X POST "$KEYCLOAK_URL/admin/realms/ozone/users" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","enabled":true}' > /dev/null
  KC_ADMIN_USER_ID=$(curl -s "$KEYCLOAK_URL/admin/realms/ozone/users?username=admin" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
  curl -s -X PUT "$KEYCLOAK_URL/admin/realms/ozone/users/$KC_ADMIN_USER_ID/reset-password" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"type":"password","value":"Admin123","temporary":false}' > /dev/null
  echo "→ Keycloak 'admin' user created (matches OpenMRS native admin)"
else
  echo "→ Keycloak 'admin' user already exists"
fi

# Create OpenMRS-role-matching realm roles and assign them to admin. These
# are read by the oauth2login module's role mapping to grant OpenMRS
# privileges on SSO login - "Privilege Level: Full" additionally has every
# OpenMRS privilege granted directly in post-start.sh's database step.
echo "=== Ensuring OpenMRS-matching realm roles exist ==="
for ROLE_NAME in "System Developer" "Privilege Level: Full" "Doctor"; do
  EXISTS=$(curl -s -o /dev/null -w "%{http_code}" "$KEYCLOAK_URL/admin/realms/ozone/roles/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$ROLE_NAME'))")" \
    -H "Authorization: Bearer $ADMIN_TOKEN")
  if [ "$EXISTS" != "200" ]; then
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/ozone/roles" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"$ROLE_NAME\",\"description\":\"Maps to OpenMRS $ROLE_NAME role for SSO users\"}" > /dev/null
    echo "→ Created role: $ROLE_NAME"
  fi
  ROLE_ID=$(curl -s "$KEYCLOAK_URL/admin/realms/ozone/roles/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$ROLE_NAME'))")" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
  curl -s -X POST "$KEYCLOAK_URL/admin/realms/ozone/users/$KC_ADMIN_USER_ID/role-mappings/realm" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "[{\"id\":\"$ROLE_ID\",\"name\":\"$ROLE_NAME\"}]" > /dev/null
done
echo "→ Realm roles assigned to admin"

# Create the radiologist/xray_technician roles (Orthanc/OE2 access - see
# permissions.json) - not assigned to any user here, assign manually per
# real staff member.
for ROLE_NAME in "radiologist" "xray_technician"; do
  EXISTS=$(curl -s -o /dev/null -w "%{http_code}" "$KEYCLOAK_URL/admin/realms/ozone/roles/$ROLE_NAME" \
    -H "Authorization: Bearer $ADMIN_TOKEN")
  if [ "$EXISTS" != "200" ]; then
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/ozone/roles" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"$ROLE_NAME\",\"description\":\"Orthanc/OE2 access role - see permissions.json\"}" > /dev/null
    echo "→ Created role: $ROLE_NAME"
  fi
done

# CRITICAL: add a User Realm Role protocol mapper to the openmrs client's
# dedicated scope, flattening real realm roles into a top-level "roles"
# claim. Without this, Keycloak's default "roles" client scope populates
# this claim from the built-in "account" client's roles only
# (manage-account etc.) - completely unrelated to OpenMRS - and the
# oauth2login module's openmrs.mapping.user.roles=roles setting silently
# reads the wrong data, regardless of what realm roles are actually
# assigned. Confirmed live: this was the true root cause of every OpenMRS
# privilege check failing (403) for SSO-authenticated users, even after
# granting every privilege in the system directly to the account.
echo "=== Ensuring openmrs client has the realm-roles-flat protocol mapper ==="
OPENMRS_CLIENT_ID=$(curl -s "$KEYCLOAK_URL/admin/realms/ozone/clients?clientId=openmrs" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")
if [ -n "$OPENMRS_CLIENT_ID" ]; then
  MAPPER_EXISTS=$(curl -s "$KEYCLOAK_URL/admin/realms/ozone/clients/$OPENMRS_CLIENT_ID/protocol-mappers/models" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('yes' if any(m.get('name')=='realm-roles-flat' for m in d) else 'no')
")
  if [ "$MAPPER_EXISTS" = "no" ]; then
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/ozone/clients/$OPENMRS_CLIENT_ID/protocol-mappers/models" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "realm-roles-flat",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-usermodel-realm-role-mapper",
        "config": {
          "claim.name": "roles",
          "jsonType.label": "String",
          "multivalued": "true",
          "id.token.claim": "true",
          "access.token.claim": "true",
          "userinfo.token.claim": "true"
        }
      }' > /dev/null
    echo "→ realm-roles-flat mapper created on openmrs client"
  else
    echo "→ realm-roles-flat mapper already exists"
  fi
else
  echo "→ WARNING: openmrs client not found - skipping mapper setup"
fi
