#!/bin/bash

set +x

export NAMESPACE="openshift-pipelines"

oc create secret generic tekton-results-postgres -n ${NAMESPACE} --from-literal=POSTGRES_USER=result --from-literal=POSTGRES_PASSWORD=$(openssl rand -base64 20)
#oc create secret generic tekton-results-postgres -n ${NAMESPACE} --from-literal=POSTGRES_USER=postgres --from-literal=POSTGRES_PASSWORD=$(openssl rand -base64 20)
#oc create secret generic tekton-results-postgres -n ${NAMESPACE} --from-literal=POSTGRESQL_USER=postgres --from-literal=POSTGRESQL_PASSWORD=$(openssl rand -base64 20) --from-literal=POSTGRESQL_DATABASE=results

echo "Generating TLS certificate"
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes \
  -subj "/CN=tekton-results-api-service.${NAMESPACE}.svc.cluster.local" \
  -addext "subjectAltName = DNS:tekton-results-api-service.${NAMESPACE}.svc.cluster.local"

echo "Creating new secret with generated certificate"
oc create secret tls -n ${NAMESPACE} tekton-results-tls --cert=cert.pem --key=key.pem 

echo "Creating a PVC for logging"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tekton-logs
  namespace: openshift-pipelines
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF

echo "Creating TektonResult CR"
cat <<EOF | oc apply -f -
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonResult
metadata:
  name: result
spec:
  targetNamespace: openshift-pipelines
  logs_api: true
  log_level: debug
  db_port: 5432
  db_user: result
  db_host: tekton-results-postgres-service.openshift-pipelines.svc.cluster.local
  logging_pvc_name: tekton-logs
  logs_path: /logs
  logs_type: File
  logs_buffer_size: 32768
  auth_disable: true
  tls_hostname_override: tekton-results-api-service.openshift-pipelines.svc.cluster.local
  db_enable_auto_migration: true
  server_port: 8080
  prometheus_port: 9090
EOF

oc create route -n ${NAMESPACE} passthrough tekton-results-api-service --service=tekton-results-api-service --port=8080

oc get tektonresults.operator.tekton.dev,tektoninstallerset

RESULTS_API=$(oc get route  tekton-results-api-service -n openshift-pipelines --no-headers -o custom-columns=":spec.host"):443

export NAMESPACE=results-testing
oc new-project $NAMESPACE

# create one task run and two pipeline runs
oc create -f task-output-image.yaml
tkn tr logs -f --last
tkn tr describe --last -o jsonpath={.metadata.annotations} | jq

oc create -f pipeline.yaml
tkn pipeline start pipeline-results --showlog
tkn pr describe --last -o jsonpath={.metadata.annotations} | jq

opc results list --insecure --addr ${RESULTS_API} ${NAMESPACE}
#opc results records list --insecure --addr ${RESULTS_API} results-testing/results/$TR_UUID
#opc results records get --insecure --addr ${RESULTS_API} results-testing/results/$TR_UUID/records/$RECORD_UUID  | jq -r .data.value | base64 -d | yq -P '.'
#opc results logs get --insecure --addr ${RESULTS_API} results-testing/results/$TR_UUID/logs/$RECORD_UUID  | jq -r .data | base64 -d


